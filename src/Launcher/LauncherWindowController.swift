import AppKit
import QuartzCore
import SwiftUI

private final class LauncherWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

/// Displays launcher and settings windows, opens logs and animates the transition to MTGO.
@MainActor
final class LauncherWindowController: NSWindowController {
  private let session: LauncherSession
  private let cancelLaunch: () -> Void
  private let restartSession: () -> Void
  private var settingsWindow: NSWindow?
  private let content = NSView()
  private var transition: Transition?

  private struct Transition {
    let id = UUID()
    let frame: NSRect
  }

  init(session: LauncherSession, cancelLaunch: @escaping () -> Void, restartSession: @escaping () -> Void) {
    self.session = session
    self.cancelLaunch = cancelLaunch
    self.restartSession = restartSession
    LauncherTheme.registerFonts()

    let window = LauncherWindow(
      contentRect: NSRect(origin: .zero, size: LauncherView.size),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.title = "MTGO"
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.isMovableByWindowBackground = true
    window.isExcludedFromWindowsMenu = true
    window.isReleasedWhenClosed = false

    super.init(window: window)
    shouldCascadeWindows = false

    let root = NSView(frame: NSRect(origin: .zero, size: LauncherView.size))
    let background = NSHostingView(rootView: LauncherBackground()
      .overlay(Rectangle().strokeBorder(.white.opacity(0.09), lineWidth: 1)))
    background.sizingOptions = []
    background.frame = root.bounds
    background.autoresizingMask = [.width, .height]
    root.addSubview(background)

    // Keep controls at their original size while the background follows the window.
    content.frame = root.bounds
    content.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
    content.wantsLayer = true
    let controls = NSHostingView(rootView: LauncherView(
      session: session,
      showSettings: { [weak self] in self?.showSettings() },
      showLogs: { [weak self] in self?.showSessionLog() },
      cancelLaunch: { [weak self] in self?.cancelLaunch() }
    ))
    controls.sizingOptions = []
    controls.frame = content.bounds
    controls.autoresizingMask = [.width, .height]
    content.addSubview(controls)
    root.addSubview(content)
    window.contentView = root
  }

  required init?(coder: NSCoder) { nil }

  func show() {
    guard let window else { return }
    cancelTransition()
    guard !window.isVisible else { return }

    NSApplication.shared.setActivationPolicy(.regular)
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
      let area = screen.visibleFrame
      // NSWindow.center() intentionally places windows above the vertical midpoint.
      window.setFrameOrigin(NSPoint(
        x: area.midX - window.frame.width / 2,
        y: area.midY - window.frame.height / 2
      ))
    }

    window.alphaValue = 1
    showWindow(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    NSLog("Presented MTGO launcher window.")
  }

  func hide() {
    settingsWindow?.orderOut(nil)
    cancelTransition()
    window?.orderOut(nil)
  }

  private func cancelTransition() {
    guard let transition, let window else { return }

    // Invalidate the old completion before replacing its in-flight animations.
    self.transition = nil
    window.orderOut(nil)

    // Retarget immediately; assigning frames alone leaves animator requests running.
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      window.animator().setFrame(transition.frame, display: false)
      window.animator().alphaValue = 1
      content.animator().alphaValue = 1
    }
  }

  func dismissForGame(
    to destination: NSRect, revealGame: (TimeInterval) -> Void,
    completion: @escaping () -> Void
  ) {
    // Keep an open Settings panel in front when startup completes.
    let finish = { [weak self] in
      if let settings = self?.settingsWindow, settings.isVisible {
        NSApplication.shared.activate(ignoringOtherApps: true)
        settings.makeKeyAndOrderFront(nil)
      }
      completion()
    }

    guard let window, window.isVisible else {
      revealGame(0)
      finish()
      return
    }

    guard session.settings.animateTransitions, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      window.orderOut(nil)
      revealGame(0)
      finish()
      return
    }

    let transition = Transition(frame: window.frame)
    self.transition = transition
    let content = self.content

    // Expand the background and reveal MTGO together, keeping launcher controls fixed.
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.20
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      window.animator().setFrame(destination, display: true)
      window.animator().alphaValue = 0
      content.animator().alphaValue = 0
      revealGame(context.duration)
    }, completionHandler: { [weak self] in
      // A later show or hide may have cancelled this transition.
      guard let self, self.transition?.id == transition.id else { return }

      self.transition = nil
      window.orderOut(nil)

      // Restore the launcher's geometry only after it is no longer visible.
      window.setFrame(transition.frame, display: false)
      window.alphaValue = 1
      content.alphaValue = 1

      finish()
    })
  }

  func showSettings() {
    if settingsWindow == nil {
      let window = SettingsWindow(session: session, restartSession: { [weak self] in
        self?.settingsWindow?.orderOut(nil)
        self?.restartSession()
      })
      settingsWindow = window
    }

    settingsWindow?.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  private func latestLog() throws -> URL? {
    let directory = session.settings.logsFolder
    let files = FileManager.default
    guard files.fileExists(atPath: directory.path) else { return nil }

    let logs = try files.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles
    ).filter {
      $0.lastPathComponent.hasPrefix("session-") && $0.pathExtension == "log"
    }.map { url in
      (url: url, modified: try url.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate ?? .distantPast)
    }

    return logs.max { $0.modified < $1.modified }?.url
  }

  func showSessionLog() {
    do {
      guard let log = try session.logURL ?? latestLog() else {
        let alert = NSAlert()
        alert.messageText = "No session logs yet"
        alert.informativeText = "Launch MTGO to create a session log."
        alert.runModal()
        return
      }

      guard NSWorkspace.shared.open(log) else {
        throw ApplicationError(message: "Could not open the session log at \(log.path).")
      }
    } catch {
      NSAlert(error: error).runModal()
    }
  }
}
