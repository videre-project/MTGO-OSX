import AppKit

/// Forwards window commands to Wine and displays attention on the native Dock entry.
@MainActor
final class DockController {
  enum WindowAction: String {
    case close, minimize, zoom
  }

  private static let ready = Notification.Name("WineAppDockProxyReady")
  private static let activated = Notification.Name("WineAppDockProxyActivated")
  private static let closed = Notification.Name("WineAppDockProxyWindowClosed")
  private static let attentionRequested = Notification.Name("WineAppDockProxyAttention")
  private static let activate = Notification.Name("WineAppDockProxyActivate")
  private static let windowAction = Notification.Name("WineAppDockProxyWindowAction")

  private let expectedExecutable: () -> URL?
  private let didAttach: () -> Void
  private let didCloseWindow: () -> Void
  private var registrations: [NSObjectProtocol] = []
  private var application: NSRunningApplication?
  private let attention = DockAttentionView()
  private var needsAttention = false
  var attentionMode: DockAttentionMode = .pulsing {
    didSet {
      guard attentionMode != oldValue else { return }

      attention.clear()
      showAttentionIfNeeded()
    }
  }
  private var returningFocusToGame = false
  private(set) var initialWindowFrame: NSRect?

  init(
    expectedExecutable: @escaping () -> URL?, didAttach: @escaping () -> Void,
    didCloseWindow: @escaping () -> Void
  ) {
    self.expectedExecutable = expectedExecutable
    self.didAttach = didAttach
    self.didCloseWindow = didCloseWindow

    // Scope notifications to this launcher; multiple prefixes can run independently.
    for name in [Self.ready, Self.activated, Self.closed, Self.attentionRequested] {
      let registration = DistributedNotificationCenter.default().addObserver(
        forName: name,
        object: String(ProcessInfo.processInfo.processIdentifier),
        queue: .main
      ) { [weak self] notification in
        guard let pid = (notification.userInfo?["pid"] as? NSNumber)?.int32Value,
          let process = notification.userInfo?["processName"] as? String,
          process.caseInsensitiveCompare("MTGO.exe") == .orderedSame else { return }

        let frame = Self.windowFrame(notification.userInfo?["frame"])
        let flags = (notification.userInfo?["flags"] as? NSNumber)?.uint32Value
        Task { @MainActor [weak self] in
          if name == Self.ready {
            self?.attach(pid: pid, frame: frame)
          } else if name == Self.activated {
            self?.takeMenuOwnership(pid: pid)
          } else if name == Self.closed {
            self?.windowClosed(pid: pid)
          } else if let flags {
            self?.updateAttention(pid: pid, flags: flags)
          }
        }
      }
      registrations.append(registration)
    }
  }

  deinit {
    for registration in registrations {
      DistributedNotificationCenter.default().removeObserver(registration)
    }
  }

  var hasWindow: Bool {
    application?.isTerminated == false && initialWindowFrame != nil
  }

  func performWindowAction(_ action: WindowAction) {
    guard let application, !application.isTerminated else { return }

    DistributedNotificationCenter.default().postNotificationName(
      Self.windowAction,
      object: String(application.processIdentifier),
      userInfo: ["ownerPID": ProcessInfo.processInfo.processIdentifier, "action": action.rawValue],
      deliverImmediately: true
    )
  }

  func activate(transitionDuration: TimeInterval = 0) {
    guard let application, !application.isTerminated else { return }

    if #available(macOS 14, *) {
      NSApplication.shared.yieldActivation(to: application)
      application.activate(from: .current, options: [])
    } else {
      application.activate(options: [.activateIgnoringOtherApps])
    }

    // Explicit reopening also restores a minimized window when Wine is already active.
    DistributedNotificationCenter.default().postNotificationName(
      Self.activate,
      object: String(application.processIdentifier),
      userInfo: [
        "ownerPID": ProcessInfo.processInfo.processIdentifier,
        "transitionDuration": transitionDuration,
      ],
      deliverImmediately: true
    )
  }

  /// Restores Wine's key window after the launcher activates its native menus.
  @discardableResult
  func finishActivation() -> Bool {
    guard returningFocusToGame else { return false }

    returningFocusToGame = false
    activate()
    return true
  }

  private func takeMenuOwnership(pid: pid_t) {
    guard let application, application.processIdentifier == pid, !application.isTerminated,
      NSWorkspace.shared.menuBarOwningApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }

    // A game-window click must update the menu bar before returning focus to Wine.
    returningFocusToGame = true
    if NSApplication.shared.isActive {
      finishActivation()
    } else if #available(macOS 14, *) {
      if !NSRunningApplication.current.activate(from: application, options: []) {
        returningFocusToGame = false
      }
    } else {
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
  }

  func hide() {
    application?.hide()
  }

  func detach() {
    clearAttention()
    returningFocusToGame = false
    application = nil
    initialWindowFrame = nil
  }

  func clearAttention() {
    needsAttention = false
    attention.clear()
  }

  func setApplicationIcon(_ image: NSImage?) {
    // AppKit may replace its Dock content when the application icon changes.
    attention.clear()
    NSApplication.shared.applicationIconImage = image
    showAttentionIfNeeded()
  }

  private func showAttentionIfNeeded() {
    guard needsAttention, attentionMode != .off else { return }

    attention.show(animated: attentionMode == .pulsing)
  }

  private func updateAttention(pid: pid_t, flags: UInt32) {
    guard let application, application.processIdentifier == pid, !application.isTerminated else { return }

    if flags == 0 { // FLASHW_STOP
      clearAttention()
    } else if flags & 2 != 0 { // FLASHW_TRAY
      // Wine receives game focus while this process supplies its menu bar and Dock icon.
      let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
      guard foreground != pid, foreground != ProcessInfo.processInfo.processIdentifier else { return }

      needsAttention = true
      showAttentionIfNeeded()
    }
  }

  private func attach(pid: pid_t, frame: NSRect?) {
    // Check the sender's executable before accepting it as this session's window process.
    guard let expected = expectedExecutable()?.resolvingSymlinksInPath(),
      let candidate = NSRunningApplication(processIdentifier: pid),
      !candidate.isTerminated,
      candidate.executableURL?.resolvingSymlinksInPath() == expected else { return }

    if application?.processIdentifier != pid { initialWindowFrame = nil }
    application = candidate
    if let frame { initialWindowFrame = frame }

    didAttach()
  }

  private nonisolated static func windowFrame(_ value: Any?) -> NSRect? {
    guard let values = value as? [String: NSNumber],
      let x = values["x"], let y = values["y"],
      let width = values["width"], let height = values["height"],
      [x, y, width, height].allSatisfy({ $0.doubleValue.isFinite }),
      width.doubleValue > 0, height.doubleValue > 0 else { return nil }
    return NSRect(x: x.doubleValue, y: y.doubleValue,
      width: width.doubleValue, height: height.doubleValue)
  }

  private func windowClosed(pid: pid_t) {
    guard application?.processIdentifier == pid else { return }
    detach()
    didCloseWindow()
  }
}
