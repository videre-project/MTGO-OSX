import AppKit
import CoreServices

/// Runs Win32 requests through the packaged Mac driver and the production Dock controller.
@main
@MainActor
final class DockAttentionTests: NSObject, NSApplicationDelegate {
  private enum Command: String {
    case attention = "a", stop = "s", caption = "c", close = "q"
  }

  private var dock: DockController!
  private var attentionReports: [UInt32] = []
  private var gamePID: pid_t?

  static func main() {
    let tests = DockAttentionTests()
    NSApplication.shared.delegate = tests
    NSApplication.shared.setActivationPolicy(.regular)
    withExtendedLifetime(tests) { NSApplication.shared.run() }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { @MainActor in
      do {
        try await self.run()
        print("PASS: background attention, stop, focus and window closure update one native Dock tile.")
        exit(0)
      } catch {
        fputs("FAIL: \(error.localizedDescription)\n", stderr)
        exit(1)
      }
    }
  }

  private func run() async throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else { throw failure("Expected runtime archive and Win32 fixture paths") }

    let activation = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { notification in
      if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
        fputs("Activated: \(app.localizedName ?? "unknown") (\(app.processIdentifier))\n", stderr)
      }
    }
    let reports = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("WineAppDockProxyAttention"),
      object: String(ProcessInfo.processInfo.processIdentifier), queue: .main
    ) { [weak self] notification in
      guard let name = notification.userInfo?["processName"] as? String,
        name.caseInsensitiveCompare("MTGO.exe") == .orderedSame,
        let flags = notification.userInfo?["flags"] as? NSNumber,
        let pid = notification.userInfo?["pid"] as? NSNumber else { return }
      fputs("Attention: \(flags.uint32Value)\n", stderr)
      Task { @MainActor [weak self] in
        self?.gamePID = pid.int32Value
        self?.attentionReports.append(flags.uint32Value)
      }
    }
    defer {
      NSWorkspace.shared.notificationCenter.removeObserver(activation)
      DistributedNotificationCenter.default().removeObserver(reports)
    }

    // AppKit needs a normal native window for the fixture's activation handoff.
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.title = "MTGO Dock attention test"
    window.center()
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }

    let menu = NSMenu()
    let applicationMenu = NSMenu(title: "MTGO Dock attention test")
    applicationMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let applicationItem = NSMenuItem()
    applicationItem.submenu = applicationMenu
    menu.addItem(applicationItem)
    NSApplication.shared.mainMenu = menu
    NSApplication.shared.activate(ignoringOtherApps: true)
    try await wait("The attention test did not become active", until: { NSApplication.shared.isActive })

    let files = FileManager.default
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_TMPDIR"] ?? NSTemporaryDirectory())
      .appendingPathComponent("dock-attention-\(UUID().uuidString)")
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }

    // Extract the release archive; Bazel may flatten symlinks in cached directory outputs.
    let runtime = root.appendingPathComponent("Runtime")
    try files.createDirectory(at: runtime, withIntermediateDirectories: true)
    let unpack = Process()
    unpack.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    unpack.arguments = ["-xJf", arguments[1], "-C", runtime.path]
    try unpack.run()
    defer { if unpack.isRunning { unpack.terminate() } }
    try await wait("Runtime extraction did not finish", timeout: 60, until: { !unpack.isRunning })
    guard unpack.terminationStatus == 0 else {
      throw failure("Could not extract the runtime (status \(unpack.terminationStatus))")
    }

    // Register the packaged helper at its final path, as RuntimeInstaller does.
    let app = runtime.appendingPathComponent("MTGO.app")
    let registrationStatus = LSRegisterURL(app as CFURL, false)
    guard registrationStatus == noErr else {
      throw failure("Could not register the runtime bundle (\(registrationStatus))")
    }

    let resources = app.appendingPathComponent("Contents/Resources")
    let loader = resources.deletingLastPathComponent().appendingPathComponent("MacOS/wine").resolvingSymlinksInPath()
    let registrations = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("WineAppDockProxyReady"),
      object: String(ProcessInfo.processInfo.processIdentifier), queue: .main
    ) { notification in
      guard let pid = notification.userInfo?["pid"] as? NSNumber,
        let name = notification.userInfo?["processName"] as? String else { return }
      Task { @MainActor in
        let app = NSRunningApplication(processIdentifier: pid.int32Value)
        let candidate = app?.executableURL?.resolvingSymlinksInPath().path ?? "unavailable"
        fputs("Registration: \(name) (\(pid)), executable=\(candidate), expected=\(loader.path)\n", stderr)
      }
    }
    defer { DistributedNotificationCenter.default().removeObserver(registrations) }

    let executable = root.appendingPathComponent("MTGO.exe")
    let commands = root.appendingPathComponent("command")
    try files.copyItem(at: URL(fileURLWithPath: arguments[2]), to: executable)
    NSApplication.shared.applicationIconImage = NSImage(contentsOf: resources.appendingPathComponent("GameIcon.icns"))

    var closed = false
    dock = DockController(expectedExecutable: { loader }, didAttach: {}, didCloseWindow: { closed = true })
    defer { dock.detach() }
    var originalDockView = NSApplication.shared.dockTile.contentView

    let process = Process()
    process.executableURL = resources.appendingPathComponent("bin/wine")
    process.arguments = [executable.path, "Z:" + commands.path.replacingOccurrences(of: "/", with: "\\")]
    process.environment = ProcessInfo.processInfo.environment.merging([
      "WINEPREFIX": root.appendingPathComponent("Prefix").path, "WINEARCH": "win64", "WINEDEBUG": "-all",
      "WINE_DOCK_OWNER_PID": String(ProcessInfo.processInfo.processIdentifier),
      "WINEDLLOVERRIDES": "winemenubuilder.exe=;mscoree=d", "WINE_DOCK_STARTUP_TRANSITION": "1",
      "MVK_CONFIG_LOG_LEVEL": "1",
      "DYLD_FALLBACK_LIBRARY_PATH": resources.appendingPathComponent("lib").path + ":/usr/lib",
    ], uniquingKeysWith: { _, new in new })
    let logDirectory = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"]
      .map { URL(fileURLWithPath: $0) } ?? root
    try files.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    let log = logDirectory.appendingPathComponent("wine.log")
    files.createFile(atPath: log.path, contents: nil)
    let output = try FileHandle(forWritingTo: log)
    process.standardOutput = output
    process.standardError = output
    defer { try? output.close() }
    defer {
      if process.isRunning { process.terminate() }
      do {
        // Wait for this prefix to stop before removing its files.
        for argument in ["-k", "-w"] {
          let server = Process()
          server.executableURL = resources.appendingPathComponent("bin/wineserver")
          server.arguments = [argument]
          server.environment = process.environment
          try server.run()
          server.waitUntilExit()
        }
      } catch {
        fputs("Could not stop the attention test's Wine prefix: \(error.localizedDescription)\n", stderr)
      }
    }

    do {
      // Set the title before loading the GUI driver; only the window process uses MTGO.exe.
      let configuration = Process()
      configuration.executableURL = process.executableURL
      configuration.arguments = [
        "reg.exe", "add", "HKCU\\Software\\Wine\\AppDefaults\\MTGO.exe\\Mac Driver",
        "/v", "MainWindowTitle", "/t", "REG_SZ", "/d", "MTGO Dock attention test", "/f",
      ]
      configuration.environment = process.environment
      configuration.standardOutput = output
      configuration.standardError = output
      try configuration.run()
      defer { if configuration.isRunning { configuration.terminate() } }
      try await wait("The Wine fixture configuration did not finish", timeout: 60, until: { !configuration.isRunning })
      guard configuration.terminationStatus == 0 else {
        throw failure("Could not configure the Wine fixture (status \(configuration.terminationStatus))")
      }

      try process.run()
      fputs("Fixture process: \(process.processIdentifier)\n", stderr)
      try await wait("Wine did not register the fixture window", timeout: 60, until: {
        guard process.isRunning else {
          throw failure("The Win32 fixture exited with status \(process.terminationStatus) before window registration")
        }
        return dock.hasWindow
      })

      // Finish the initial Wine focus exchange before testing background attention.
      try await send(.stop, to: commands)
      try await wait("Wine did not identify the GUI process", until: { gamePID != nil })
      try await activateGame()

      // The Mac driver allows delayed activation for two seconds during startup.
      try await pause(2.1)

      try await activateFinder()

      try await send(.caption, to: commands)
      try await pause(0.3)
      guard !(NSApplication.shared.dockTile.contentView is DockAttentionView) else {
        throw failure("Caption-only flashing displayed a Dock indicator")
      }

      try await send(.attention, to: commands)
      try await wait("Background taskbar attention did not display a Dock indicator", until: {
        NSApplication.shared.dockTile.contentView is DockAttentionView
      })
      let initial = try iconPixels()
      try await pause(0.55)
      if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        guard try iconPixels() != initial else { throw failure("The attention indicator did not animate") }
      }
      try await pause(2.3)
      guard NSApplication.shared.dockTile.contentView is DockAttentionView else {
        throw failure("Attention disappeared before acknowledgement")
      }
      let steady = try iconPixels()
      try await pause(0.15)
      guard try iconPixels() == steady else { throw failure("The indicator did not settle after two pulses") }
      let foreground = NSWorkspace.shared.frontmostApplication
      guard foreground?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
        foreground?.processIdentifier != gamePID else {
        throw failure("Attention activated \(foreground?.localizedName ?? "the native host")")
      }

      // Preferences apply to pending attention without another Windows request.
      dock.attentionMode = .off
      guard NSApplication.shared.dockTile.contentView === originalDockView else {
        throw failure("Disabling attention did not restore the original Dock tile")
      }
      dock.attentionMode = .steady
      let unanimated = try iconPixels()
      try await pause(0.3)
      guard try iconPixels() == unanimated else { throw failure("Steady attention animated") }

      let replacement = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
        NSColor.systemBlue.setFill()
        rect.fill()
        return true
      }
      dock.setApplicationIcon(replacement)
      guard NSApplication.shared.dockTile.contentView is DockAttentionView,
        try iconPixels() != unanimated else {
        throw failure("Changing the app icon lost pending attention or retained the old image")
      }
      dock.attentionMode = .off
      originalDockView = NSApplication.shared.dockTile.contentView
      dock.attentionMode = .pulsing

      try await send(.stop, to: commands)
      try await wait("FLASHW_STOP did not restore the original Dock tile", until: { NSApplication.shared.dockTile.contentView === originalDockView })
      try await send(.attention, to: commands)
      try await wait("A second attention request did not display the indicator", until: { NSApplication.shared.dockTile.contentView is DockAttentionView })
      let reportsBeforeFocus = attentionReports.count
      try await activateGame()
      try await wait("Wine did not clear attention on activation", until: {
        attentionReports.dropFirst(reportsBeforeFocus).contains(0)
      })
      guard NSApplication.shared.dockTile.contentView === originalDockView else {
        throw failure("Returning to the Wine window did not restore the original Dock tile")
      }

      try await send(.attention, to: commands)
      try await pause(0.3)
      guard !(NSApplication.shared.dockTile.contentView is DockAttentionView) else {
        throw failure("Foreground attention displayed an indicator")
      }

      // Closing the window also clears an outstanding background indicator.
      try await activateFinder()
      try await send(.attention, to: commands)
      try await wait("Attention did not appear before window closure", until: {
        NSApplication.shared.dockTile.contentView is DockAttentionView
      })
      try await send(.close, to: commands)
      try await wait("Window destruction did not detach the Dock controller", until: { closed })
      guard NSApplication.shared.dockTile.contentView === originalDockView else {
        throw failure("Closing the window did not restore the original Dock tile")
      }
    } catch {
      if let text = try? String(contentsOf: log) { fputs(text, stderr) }
      throw error
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    dock?.clearAttention()
    _ = dock?.finishActivation()
  }

  private func activateGame() async throws {
    NSApplication.shared.activate(ignoringOtherApps: true)
    try await wait("The native Dock owner did not activate", until: { NSApplication.shared.isActive })
    dock.activate()
    try await wait("The Wine fixture did not regain foreground focus", until: {
      NSWorkspace.shared.frontmostApplication?.processIdentifier == gamePID
        && NSWorkspace.shared.menuBarOwningApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    })
  }

  private func activateFinder() async throws {
    NSApplication.shared.activate(ignoringOtherApps: true)
    try await wait("The native host did not regain focus", until: { NSApplication.shared.isActive })
    guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
      throw failure("Finder is not running")
    }
    if #available(macOS 14, *) {
      NSApplication.shared.yieldActivation(to: finder)
      finder.activate(from: .current, options: [])
    } else {
      finder.activate(options: [.activateIgnoringOtherApps])
    }
    try await wait("Finder did not become foreground", until: {
      NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier
    })
  }

  private func send(_ command: Command, to file: URL) async throws {
    fputs("Command: \(command)\n", stderr)
    try command.rawValue.write(to: file, atomically: true, encoding: .utf8)
    try await wait("The Windows fixture did not acknowledge command '\(command)'", until: {
      (try? String(contentsOf: file)) == command.rawValue + "!"
    })
  }

  private func iconPixels() throws -> Data {
    guard let view = NSApplication.shared.dockTile.contentView,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw failure("Could not render the Dock indicator")
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let pixels = bitmap.representation(using: .png, properties: [:]) else {
      throw failure("Could not encode the Dock indicator")
    }
    return pixels
  }

  private func wait(_ message: String, timeout: TimeInterval = 15, until condition: () throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(try condition()) {
      guard Date() < deadline else {
        let foreground = NSWorkspace.shared.frontmostApplication
        throw failure("\(message). Foreground: \(foreground?.localizedName ?? "none") (\(foreground?.processIdentifier ?? 0))")
      }
      try await pause(0.02)
    }
  }

  private func pause(_ duration: TimeInterval) async throws {
    try await Task.sleep(for: .seconds(duration))
  }

  private func failure(_ message: String) -> NSError {
    NSError(domain: "DockAttentionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
