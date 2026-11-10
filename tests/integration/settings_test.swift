import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Exercises saved preferences, imported files and the actual native settings panes.
@main
@MainActor
final class SettingsTests: NSObject, NSApplicationDelegate {
  static func main() {
    let tests = SettingsTests()
    NSApplication.shared.delegate = tests
    NSApplication.shared.setActivationPolicy(.regular)
    withExtendedLifetime(tests) { NSApplication.shared.run() }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { @MainActor in
      do {
        try await run()
        exit(0)
      } catch {
        fputs("FAIL: \(error.localizedDescription)\n", stderr)
        exit(1)
      }
    }
  }

  private func run() async throws {
    guard CommandLine.arguments.count == 2 else { throw failure("Expected the app resource directory") }
    let resources = URL(fileURLWithPath: CommandLine.arguments[1])
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_TMPDIR"] ?? NSTemporaryDirectory())
      .appendingPathComponent("settings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let domain = "MTGO.SettingsTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: domain) else { throw failure("Could not create isolated preferences") }
    defer { defaults.removePersistentDomain(forName: domain) }
    let environment = [
      "MTGO_ICON_CACHE": root.appendingPathComponent("Icons").path,
      "MTGO_RUNTIME_CACHE": root.appendingPathComponent("Runtimes").path,
      "MTGO_PREFIX_ROOT": root.appendingPathComponent("Prefix").path,
      "MTGO_PACKAGE_CACHE": root.appendingPathComponent("Downloads").path,
    ]
    let settings = LauncherSettings(defaults: defaults, environment: environment, resources: resources)

    try require(settings.showStartupProgress && settings.animateTransitions && settings.attentionMode == .pulsing,
      "A fresh installation must keep startup progress, transitions and pulsing attention enabled")
    try testIconImport(settings: settings, defaults: defaults, environment: environment, resources: resources, root: root)
    try testPreferencePersistence(settings: settings, defaults: defaults, environment: environment, resources: resources)
    try testUserDataPreference(settings: settings, defaults: defaults, environment: environment, resources: resources, root: root)
    try await testNativePanes(settings: settings, defaults: defaults)
    try testImmediateTransition(settings: settings, defaults: defaults)
    try await testStorageExcludesHostLinks(root: root)
    print("PASS: settings persist, custom icons survive source deletion, native panes restore selection, and storage excludes host links.")
  }

  private func testIconImport(
    settings: LauncherSettings, defaults: UserDefaults, environment: [String: String], resources: URL, root: URL
  ) throws {
    let source = root.appendingPathComponent("portrait.png")
    guard let context = CGContext(data: nil, width: 8, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil) else {
      throw failure("Could not create the image fixture")
    }
    context.setFillColor(NSColor.systemRed.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 16))
    guard let image = context.makeImage() else { throw failure("Could not draw the image fixture") }
    CGImageDestinationAddImage(destination, image, nil)
    try require(CGImageDestinationFinalize(destination), "Could not save the image fixture")

    try settings.selectIcon(source)
    guard let imported = settings.customIconURL else { throw failure("Image import did not select an icon") }
    try require(imported != source && imported.path.hasPrefix(root.appendingPathComponent("Icons").path + "/"),
      "Custom images must be copied into app storage")
    try settings.selectIcon(source)
    try require(settings.customIconURL == imported, "Reimporting the same image must reuse its file")

    guard let decoded = CGImageSourceCreateWithURL(imported as CFURL, nil),
      let square = CGImageSourceCreateImageAtIndex(decoded, 0, nil) else { throw failure("Imported image is unreadable") }
    try require(square.width == 1024 && square.height == 1024, "Custom icons must have a square canvas")
    guard let pixels = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let data = pixels.data else { throw failure("Could not inspect the imported icon") }
    pixels.draw(square, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let bytes = data.assumingMemoryBound(to: UInt8.self)
    try require(bytes[512 * 4096 + 3] == 0 && bytes[512 * 4096 + 512 * 4 + 3] == 255,
      "Portrait images must retain transparent side padding and visible center pixels")

    let invalid = root.appendingPathComponent("invalid.png")
    try Data("Not an image".utf8).write(to: invalid)
    do {
      try settings.selectIcon(invalid)
      throw failure("Invalid images must be rejected")
    } catch is ApplicationError {
      try require(settings.customIconURL == imported, "Failed imports must preserve the selected icon")
    }

    try FileManager.default.removeItem(at: source)
    let reopened = LauncherSettings(defaults: defaults, environment: environment, resources: resources)
    try require(reopened.customIconURL == imported && reopened.iconImage != nil,
      "The selected icon must survive relaunch after the original image is deleted")
    try FileManager.default.removeItem(at: imported)
    let missing = LauncherSettings(defaults: defaults, environment: environment, resources: resources)
    try require(missing.customIconURL == nil && missing.iconURL == resources.appendingPathComponent("GameIcon.icns"),
      "A missing custom image must fall back to the packaged icon")
    settings.resetIcon()
    try require(settings.customIconURL == nil && settings.iconURL == resources.appendingPathComponent("GameIcon.icns"),
      "Reset must select the packaged MTGO icon")
  }

  private func testPreferencePersistence(
    settings: LauncherSettings, defaults: UserDefaults, environment: [String: String], resources: URL
  ) throws {
    settings.attentionMode = .steady
    settings.animateTransitions = false
    settings.showStartupProgress = false
    let reopened = LauncherSettings(defaults: defaults, environment: environment, resources: resources)
    try require(reopened.attentionMode == .steady && !reopened.animateTransitions && !reopened.showStartupProgress,
      "Behavior and appearance preferences must survive relaunch")

    // UserDefaults also receives string values from command-line overrides.
    defaults.set("NO", forKey: "showStartupProgress")
    defaults.set("YES", forKey: "animateTransitions")
    let overridden = LauncherSettings(defaults: defaults, environment: environment, resources: resources)
    try require(!overridden.showStartupProgress && overridden.animateTransitions,
      "Command-line Boolean defaults must use the same meaning as saved preferences")
  }

  private func testUserDataPreference(
    settings: LauncherSettings, defaults: UserDefaults, environment: [String: String], resources: URL, root: URL
  ) throws {
    let folder = root.appendingPathComponent("UserData")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let path = WineUserData.directory(in: settings.prefixFolder)
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: folder)
    let manual = LauncherSettings(defaults: defaults, environment: environment, resources: resources)
    try require(manual.userDataFolder?.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path,
      "Existing manual data links must be retained; got \(String(describing: manual.userDataFolder?.path)), expected \(folder.path)")

    let originalPrefix = settings.prefixFolder
    let otherPrefix = root.appendingPathComponent("OtherPrefix")
    let otherFolder = root.appendingPathComponent("OtherData")
    let otherPath = WineUserData.directory(in: otherPrefix)
    try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: otherPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: otherPath, withDestinationURL: otherFolder)
    settings.selectPrefix(otherPrefix)
    try require(settings.userDataFolder?.resolvingSymlinksInPath().path == otherFolder.resolvingSymlinksInPath().path,
      "Selecting another prefix must adopt its manual mapping when no preference was saved")

    try settings.selectUserData(folder)
    let saved = LauncherSettings(defaults: defaults, environment: environment, resources: resources)
    try require(saved.userDataFolder?.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path,
      "The chosen user data folder must survive relaunch")
    settings.selectPrefix(originalPrefix)
    settings.selectPrefix(otherPrefix)
    try require(settings.userDataFolder?.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path,
      "An explicit user data selection must take precedence over a prefix's manual mapping")

    settings.useDefaultUserData()
    settings.selectPrefix(originalPrefix)
    try require(settings.userDataFolder == nil, "An explicit reset must remain selected when the prefix changes")
    let reset = LauncherSettings(defaults: defaults, environment: environment, resources: resources)
    try require(reset.userDataFolder == nil, "An explicit reset must take precedence over the old symlink until restart")
  }

  private func testNativePanes(settings: LauncherSettings, defaults: UserDefaults) async throws {
    let session = LauncherSession(settings: settings, defaults: defaults)
    let window = SettingsWindow(session: session, defaults: defaults, restartSession: {})
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    guard let tabs = window.contentViewController as? NSTabViewController else { throw failure("Settings require native toolbar panes") }
    try require(tabs.tabViewItems.map(\.label) == ["Appearance", "Behavior", "Runtime"], "The settings toolbar must expose all three panes")
    for (index, item) in tabs.tabViewItems.enumerated() {
      tabs.selectedTabViewItemIndex = index
      try await Task.sleep(for: .milliseconds(250))
      try require(window.title == item.label, "The window title must identify the selected pane")
      try require((window.contentView?.bounds.width ?? 0) >= 560,
        "Settings content must fit the window; actual size: \(String(describing: window.contentView?.bounds.size))")
      if let output = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"],
        let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(
          to: URL(fileURLWithPath: output).appendingPathComponent(item.label + ".png"))
      }
    }
    let restored = SettingsWindow(session: session, defaults: defaults, restartSession: {})
    defer { restored.close() }
    try require((restored.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex == 2,
      "Reopening Settings must restore the last selected pane")
  }

  private func testImmediateTransition(settings: LauncherSettings, defaults: UserDefaults) throws {
    settings.animateTransitions = false
    let session = LauncherSession(settings: settings, defaults: defaults)
    let launcher = LauncherWindowController(session: session, cancelLaunch: {}, restartSession: {})
    launcher.show()
    defer { launcher.hide() }
    var duration: TimeInterval?
    var completed = false
    launcher.dismissForGame(to: NSRect(x: 100, y: 100, width: 900, height: 600), revealGame: { duration = $0 }) {
      completed = true
    }
    try require(duration == 0 && completed && launcher.window?.isVisible == false,
      "Disabling transitions must reveal MTGO immediately and hide the launcher")
  }

  private func testStorageExcludesHostLinks(root: URL) async throws {
    let prefix = root.appendingPathComponent("StoragePrefix")
    let host = root.appendingPathComponent("HostFiles")
    let missing = await StorageUsage.size(of: prefix)
    try require(missing == nil, "A missing folder must report unavailable storage")
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: prefix.appendingPathComponent("owned"))
    try Data(repeating: 2, count: 1_048_576).write(to: host.appendingPathComponent("unrelated"))
    let before = await StorageUsage.size(of: prefix)
    try FileManager.default.createSymbolicLink(at: prefix.appendingPathComponent("z:"), withDestinationURL: host)
    let after = await StorageUsage.size(of: prefix)
    try require(before != nil && before == after, "Storage totals must not follow Wine links into host folders")
  }

  private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw failure(message) }
  }

  private func failure(_ message: String) -> NSError {
    NSError(domain: "SettingsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
