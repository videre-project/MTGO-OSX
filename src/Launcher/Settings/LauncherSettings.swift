import AppKit
import Combine
import Foundation

/// Saved launcher preferences and environment overrides for this app instance.
@MainActor
final class LauncherSettings: ObservableObject {
  @Published private(set) var runtimeFolder: URL?
  @Published private(set) var usesCustomRuntime = false
  @Published private(set) var prefixFolder: URL
  @Published private(set) var userDataFolder: URL?
  @Published private(set) var customIconURL: URL?
  @Published var attentionMode: DockAttentionMode {
    didSet { defaults.set(attentionMode.rawValue, forKey: "attentionMode") }
  }
  @Published var showStartupProgress: Bool {
    didSet { defaults.set(showStartupProgress, forKey: "showStartupProgress") }
  }
  @Published var animateTransitions: Bool {
    didSet { defaults.set(animateTransitions, forKey: "animateTransitions") }
  }
  @Published var softwareRendering: Bool {
    didSet { defaults.set(softwareRendering, forKey: "softwareRendering") }
  }

  let packageCache: URL
  let runtimeDirectory: URL
  let runtimeCatalog: URL?
  let logsFolder: URL

  private let defaults: UserDefaults
  private let iconsFolder: URL
  private let defaultIconURL: URL?

  var iconURL: URL? { customIconURL ?? defaultIconURL }
  var iconImage: NSImage? { iconURL.flatMap { NSImage(contentsOf: $0) } }
  var userDataDirectory: URL { userDataFolder ?? WineUserData.directory(in: prefixFolder) }

  private static let applicationSupport = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("MTGO-OSX", isDirectory: true)

  init(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    resources: URL? = Bundle.main.resourceURL
  ) {
    self.defaults = defaults
    defaults.register(defaults: ["showStartupProgress": true, "animateTransitions": true])
    attentionMode = defaults.string(forKey: "attentionMode").flatMap(DockAttentionMode.init(rawValue:)) ?? .pulsing
    showStartupProgress = defaults.bool(forKey: "showStartupProgress")
    animateTransitions = defaults.bool(forKey: "animateTransitions")
    softwareRendering = defaults.bool(forKey: "softwareRendering")

    defaultIconURL = resources?.appendingPathComponent("GameIcon.icns")
    iconsFolder = environment["MTGO_ICON_CACHE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? Self.applicationSupport.appendingPathComponent("Icons", isDirectory: true)
    if let name = defaults.string(forKey: "customIcon"),
      name == (name as NSString).lastPathComponent,
      NSImage(contentsOf: iconsFolder.appendingPathComponent(name)) != nil {
      customIconURL = iconsFolder.appendingPathComponent(name)
    }

    runtimeDirectory = environment["MTGO_RUNTIME_CACHE"].map {
      URL(fileURLWithPath: $0, isDirectory: true)
    } ?? Self.applicationSupport.appendingPathComponent("Runtimes", isDirectory: true)
    runtimeCatalog = environment["MTGO_RUNTIME_CATALOG"].map { URL(fileURLWithPath: $0) }
      ?? resources?.appendingPathComponent("RuntimePackages.json")

    // Explicit overrides take precedence over automatic runtime installation.
    let bundledRuntime = resources?.appendingPathComponent("Runtime", isDirectory: true)
    if let path = environment["MTGO_RUNTIME_ROOT"] {
      runtimeFolder = URL(fileURLWithPath: path, isDirectory: true)
    } else if environment["MTGO_RUNTIME_CATALOG"] == nil, let path = defaults.string(forKey: "runtimeFolder") {
      runtimeFolder = URL(fileURLWithPath: path, isDirectory: true)
    } else if environment["MTGO_RUNTIME_CATALOG"] == nil, let bundledRuntime,
      FileManager.default.fileExists(atPath: bundledRuntime.appendingPathComponent("runtime.json").path) {
      runtimeFolder = bundledRuntime
    }

    // Preserve existing ARM64 installations; new prefixes are separated by architecture.
    let legacyPrefix = Self.applicationSupport.appendingPathComponent("Prefix", isDirectory: true)
    let hasLegacyPrefix = RuntimePackage.nativeArchitecture == "arm64"
      && FileManager.default.fileExists(atPath: legacyPrefix.appendingPathComponent("system.reg").path)
    let defaultPrefix = hasLegacyPrefix ? legacyPrefix
      : Self.applicationSupport.appendingPathComponent("Prefixes/\(RuntimePackage.nativeArchitecture)", isDirectory: true)
    let prefix = environment["MTGO_PREFIX_ROOT"]
      ?? defaults.string(forKey: "prefixFolder")
      ?? defaultPrefix.path
    prefixFolder = URL(fileURLWithPath: prefix, isDirectory: true)

    userDataFolder = Self.selectedUserData(in: URL(fileURLWithPath: prefix, isDirectory: true), defaults: defaults)

    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    packageCache = environment["MTGO_PACKAGE_CACHE"].map {
      URL(fileURLWithPath: $0, isDirectory: true)
    } ?? caches.appendingPathComponent("MTGO-OSX/Packages", isDirectory: true)

    logsFolder = environment["MTGO_LOG_ROOT"].map {
      URL(fileURLWithPath: $0, isDirectory: true)
    } ?? Self.applicationSupport.appendingPathComponent("Logs", isDirectory: true)

    usesCustomRuntime = runtimeFolder != nil
  }

  func selectRuntime(_ folder: URL) {
    runtimeFolder = folder
    usesCustomRuntime = true
    defaults.set(folder.path, forKey: "runtimeFolder")
  }

  func useAutomaticRuntime() {
    runtimeFolder = nil
    usesCustomRuntime = false
    defaults.removeObject(forKey: "runtimeFolder")
  }

  func installedRuntime(_ folder: URL) {
    // A folder chosen during preparation applies to the next session.
    guard !usesCustomRuntime else { return }

    runtimeFolder = folder
  }

  func selectPrefix(_ folder: URL) {
    prefixFolder = folder
    defaults.set(folder.path, forKey: "prefixFolder")
    userDataFolder = Self.selectedUserData(in: folder, defaults: defaults)
  }

  func selectUserData(_ folder: URL) throws {
    try WineUserData.validate(folder, for: prefixFolder)

    defaults.set(folder.path, forKey: "userDataFolder")
    userDataFolder = folder
  }

  func useDefaultUserData() {
    // An empty preference distinguishes reset from an existing manual symlink.
    defaults.set("", forKey: "userDataFolder")
    userDataFolder = nil
  }

  func selectIcon(_ source: URL) throws {
    let url = try CustomIcon.importImage(from: source, into: iconsFolder)
    defaults.set(url.lastPathComponent, forKey: "customIcon")
    customIconURL = url
  }

  func resetIcon() {
    defaults.removeObject(forKey: "customIcon")
    customIconURL = nil
  }

  private static func selectedUserData(in prefix: URL, defaults: UserDefaults) -> URL? {
    if let path = defaults.string(forKey: "userDataFolder") {
      return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    // Preserve manual mappings only while no folder or reset has been saved.
    let data = WineUserData.directory(in: prefix)
    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: data.path) else { return nil }
    return URL(fileURLWithPath: target, relativeTo: data.deletingLastPathComponent()).standardizedFileURL
  }
}
