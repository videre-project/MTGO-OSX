import AppKit
import Combine
import CoreServices

/// Starts MTGO and handles native menus, window activation and shutdown.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  private let session: LauncherSession
  private lazy var launcher = LauncherWindowController(
    session: session, cancelLaunch: { [weak self] in self?.cancelLaunch() },
    restartSession: { [weak self] in self?.restartSession() }
  )
  private var subscriptions = Set<AnyCancellable>()
  private lazy var dock = DockController(
    expectedExecutable: { [weak self] in self?.session.gameExecutableURL },
    didAttach: { [weak self] in
      guard let self, self.session.isRunning else { return }
      if self.gamePresented {
        self.activateGame()
      } else {
        self.presentGame()
      }
    },
    didCloseWindow: { [weak self] in self?.session.mainWindowClosed() }
  )
  private var pendingTermination = false
  private var gamePresented = false
  private var reopenAfterExit = false

  init(session: LauncherSession) {
    self.session = session
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    installMenu()

    // Register for Wine notifications before starting its processes.
    _ = dock
    dock.setApplicationIcon(session.settings.iconImage)
    dock.attentionMode = session.settings.attentionMode

    // Native preferences apply now; Wine captures its icon when a session starts.
    session.settings.$customIconURL.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
      guard let self else { return }

      self.dock.setApplicationIcon(self.session.settings.iconImage)
    }.store(in: &subscriptions)
    session.settings.$attentionMode.dropFirst().receive(on: RunLoop.main).sink { [weak self] mode in
      self?.dock.attentionMode = mode
    }.store(in: &subscriptions)

    // Wait until a closing launcher window has left the app's visible windows.
    NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
      .receive(on: RunLoop.main).sink { [weak self] _ in self?.activateGameIfReady() }
      .store(in: &subscriptions)

    // @Published emits before storage changes; presentation also reads session.state.
    session.$state.dropFirst().receive(on: RunLoop.main).sink { [weak self] state in
      self?.updatePresentation(for: state)
    }.store(in: &subscriptions)

    if CommandLine.arguments.contains("--preview") {
      launcher.show()
      Task { await session.refreshVersion() }
    } else {
      session.launch()
    }
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  private func installMenu() {
    let application = NSApplication.shared
    let menu = NSMenu()

    func submenu(_ title: String) -> NSMenu {
      let submenu = NSMenu(title: title)
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.submenu = submenu
      menu.addItem(item)
      return submenu
    }

    let applicationMenu = submenu("MTGO")
    applicationMenu.addItem(
      withTitle: "About MTGO", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: ""
    )
    applicationMenu.addItem(.separator())
    applicationMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
    applicationMenu.addItem(withTitle: "Show Session Log", action: #selector(showSessionLog), keyEquivalent: "")
    applicationMenu.addItem(.separator())

    let services = NSMenu(title: "Services")
    let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    servicesItem.submenu = services
    applicationMenu.addItem(servicesItem)
    application.servicesMenu = services
    applicationMenu.addItem(.separator())
    applicationMenu.addItem(withTitle: "Hide MTGO", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let hideOthers = applicationMenu.addItem(
      withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"
    )
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    applicationMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    applicationMenu.addItem(.separator())
    applicationMenu.addItem(withTitle: "Quit MTGO", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    let fileMenu = submenu("File")
    fileMenu.addItem(withTitle: "Close Window", action: #selector(performClose(_:)), keyEquivalent: "w").target = self

    // Native text controls use AppKit's responder chain for editing and undo.
    let editMenu = submenu("Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

    // Forward window commands to the Wine process displaying MTGO.
    let windowMenu = submenu("Window")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(performMiniaturize(_:)), keyEquivalent: "m").target = self
    windowMenu.addItem(withTitle: "Zoom", action: #selector(performZoom(_:)), keyEquivalent: "").target = self
    windowMenu.addItem(.separator())
    windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(arrangeInFront(_:)), keyEquivalent: "").target = self
    windowMenu.addItem(.separator())
    windowMenu.addItem(withTitle: "MTGO", action: #selector(showGameWindow), keyEquivalent: "0").target = self
    application.windowsMenu = windowMenu

    let helpMenu = submenu("Help")
    helpMenu.addItem(withTitle: "MTGO Help", action: #selector(showMTGOHelp), keyEquivalent: "?").target = self
    helpMenu.addItem(withTitle: "MTGO Forums", action: #selector(showMTGOForums), keyEquivalent: "").target = self
    application.helpMenu = helpMenu
    application.mainMenu = menu
  }

  private var activeNativeWindow: NSWindow? {
    let application = NSApplication.shared
    guard application.isActive,
      let window = application.keyWindow ?? application.mainWindow, window.isVisible else { return nil }

    return window
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(performClose(_:)):
      if let window = activeNativeWindow {
        return window === launcher.window || window.styleMask.contains(.closable)
      }
      return session.isRunning && dock.hasWindow
    case #selector(performMiniaturize(_:)):
      if let window = activeNativeWindow { return window.styleMask.contains(.miniaturizable) }
      return session.isRunning && dock.hasWindow
    case #selector(performZoom(_:)):
      if let window = activeNativeWindow { return window.styleMask.contains(.resizable) }
      return session.isRunning && dock.hasWindow
    case #selector(showGameWindow):
      return session.isRunning && dock.hasWindow
    case #selector(arrangeInFront(_:)):
      return NSApplication.shared.windows.contains(where: \.isVisible) || (session.isRunning && dock.hasWindow)
    default:
      return true
    }
  }

  @objc private func performClose(_ sender: Any?) {
    if let window = activeNativeWindow {
      if window === launcher.window {
        NSApplication.shared.terminate(sender)
      } else {
        window.performClose(sender)
      }
    } else if session.isRunning {
      dock.performWindowAction(.close)
    }
  }

  @objc private func performMiniaturize(_ sender: Any?) {
    if let window = activeNativeWindow {
      window.performMiniaturize(sender)
    } else if session.isRunning {
      dock.performWindowAction(.minimize)
    }
  }

  @objc private func performZoom(_ sender: Any?) {
    if let window = activeNativeWindow {
      window.performZoom(sender)
    } else if session.isRunning {
      dock.performWindowAction(.zoom)
    }
  }

  @objc private func arrangeInFront(_ sender: Any?) {
    NSApplication.shared.arrangeInFront(sender)
    if session.isRunning { dock.activate() }
  }

  @objc private func showGameWindow() { dock.activate() }

  @objc private func showMTGOHelp() {
    NSWorkspace.shared.open(URL(string: "https://help.mtgo.com/hc/en-us")!)
  }

  @objc private func showMTGOForums() {
    NSWorkspace.shared.open(URL(string: "https://forums.mtgo.com/")!)
  }

  @objc private func showSessionLog() { launcher.showSessionLog() }

  @objc private func showSettings() { launcher.showSettings() }

  private func updatePresentation(for state: LauncherState) {
    // Reopen the launcher process already using this prefix.
    if case .existingSession(let pid) = state {
      reopenExistingSession(pid: pid)
      NSApplication.shared.terminate(nil)
      return
    }

    if !state.isBusy {
      dock.detach()
      gamePresented = false
    }

    // Complete AppKit's deferred quit only after session cleanup has finished.
    if pendingTermination {
      if case .stopFailed = state {
        pendingTermination = false
        NSApplication.shared.reply(toApplicationShouldTerminate: false)
        launcher.show()
      } else if !state.isBusy {
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
      }
      return
    }

    switch state {
    case .running:
      presentGame()
    case .closing:
      if !reopenAfterExit { hideClosingSession() }
    case .ended:
      // Reopening during shutdown must wait until the prefix lock is released.
      let reopen = reopenAfterExit
      reopenAfterExit = false
      if reopen {
        session.launch()
      } else {
        NSApplication.shared.terminate(nil)
      }
    case .failed, .stopped:
      reopenAfterExit = false
      launcher.show()
    case .preparing, .launching:
      if session.settings.showStartupProgress || session.requiresProgressWindow || launcher.window?.isVisible == true {
        launcher.show()
      }
    case .stopFailed:
      launcher.show()
    case .idle, .existingSession, .stopping:
      break
    }
  }

  private func hideClosingSession() {
    launcher.hide()
    NSApplication.shared.setActivationPolicy(.accessory)
  }

  private func cancelLaunch() {
    reopenAfterExit = false

    if session.state == .closing {
      hideClosingSession()
    } else {
      session.stop()
    }
  }

  private func restartSession() {
    guard session.isRunning, session.requiresRestart, !pendingTermination else { return }

    // Relaunch only after shutdown releases the current prefix.
    reopenAfterExit = true
    session.prepareForRelaunch()
    session.stop()
    launcher.show()
  }

  private func presentGame() {
    // SDK startup and Wine window readiness may arrive in either order.
    guard session.isRunning, !pendingTermination, !gamePresented,
      let frame = dock.initialWindowFrame else { return }

    gamePresented = true
    launcher.dismissForGame(to: frame, revealGame: { [weak self] duration in
      guard let self, self.session.isRunning, !self.pendingTermination else { return }

      NSApplication.shared.activate(ignoringOtherApps: true)
      self.dock.activate(transitionDuration: duration)
    }) { [weak self] in
      guard let self else { return }

      if self.session.state.needsWindow {
        self.launcher.show()
      } else {
        self.activateGame()
      }
    }
  }

  private func reopenExistingSession(pid: pid_t) {
    guard let owner = NSRunningApplication(processIdentifier: pid), !owner.isTerminated else { return }

    let application = NSApplication.shared
    if #available(macOS 14, *) {
      application.yieldActivation(to: owner)
      owner.activate(from: .current, options: [])
    } else {
      owner.activate(options: [.activateIgnoringOtherApps])
    }

    // Activation alone does not restore minimized windows or queue a relaunch.
    let reopen = NSAppleEventDescriptor(
      eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
      targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
      returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
    )
    do {
      _ = try reopen.sendEvent(options: .noReply, timeout: 5)
    } catch {
      NSLog("Could not reopen the existing MTGO session: %@", error.localizedDescription)
    }
  }

  private func activateGame() {
    let application = NSApplication.shared
    guard session.isRunning, !pendingTermination,
      !application.windows.contains(where: { $0.isVisible }) else { return }

    // Reactivating the launcher here can loop through applicationDidBecomeActive.
    dock.activate()
  }

  private func activateGameIfReady() {
    guard NSApplication.shared.isActive else { return }

    activateGame()
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    dock.clearAttention()
    if !dock.finishActivation() { activateGameIfReady() }
  }

  func applicationDidHide(_ notification: Notification) {
    dock.hide()
  }

  func applicationDidUnhide(_ notification: Notification) {
    activateGameIfReady()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows visible: Bool) -> Bool {
    if session.state == .closing {
      reopenAfterExit = true
      session.prepareForRelaunch()
      launcher.show()
    } else if session.isRunning {
      activateGame()
    } else if !visible && (!session.isBusy || session.state.needsWindow || session.failure != nil) {
      launcher.show()
    }

    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    !session.isBusy
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard session.isBusy else { return .terminateNow }

    if session.state == .closing {
      reopenAfterExit = false
      hideClosingSession()
      pendingTermination = true
      return .terminateLater
    }

    if pendingTermination { return .terminateLater }

    let alert = NSAlert()
    alert.messageText = "Stop MTGO and quit?"
    alert.informativeText = "MTGO will close, and any installation in progress will stop."
    alert.addButton(withTitle: "Stop and Quit")
    alert.addButton(withTitle: "Cancel")

    guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

    pendingTermination = true
    session.stop()
    return .terminateLater
  }
}
