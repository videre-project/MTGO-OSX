import Foundation

private struct RuntimeManifest: Decodable {
  let schemaVersion: Int
  let dockProtocolVersion: Int?
  let architecture: RuntimeArchitecture
  let minimumMacOSVersion: String?
  let wine: String
  let wineLoader: String
  let wineserver: String
  let macDriver: String
  let windowsRuntime: String
  let direct3D9: String?
  let vulkanLibrary: String?
}

/// Validated native Wine binaries and the prefix used by one MTGO session.
struct WineRuntime {
  let architecture: RuntimeArchitecture
  let prefix: URL
  let wine: URL
  let wineLoader: URL
  let wineserver: URL
  let archiver: URL
  let direct3D9: URL?

  static func load(root: URL, prefix: URL) throws -> WineRuntime {
    let data = try Data(contentsOf: root.appendingPathComponent("runtime.json"))
    let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: data)
    guard manifest.schemaVersion == 2, manifest.architecture == .native else {
      throw ApplicationError(message: "This build requires a \(RuntimeArchitecture.native.rawValue) macOS runtime (manifest version 2).")
    }
    let architecture = manifest.architecture

    // The Mac driver must support window handoff, menu commands and taskbar attention.
    guard manifest.dockProtocolVersion == 5 else {
      throw ApplicationError(message: "The selected Wine runtime is incompatible with this launcher. Use the automatic runtime in Settings.")
    }
    try validateMacOSVersion(manifest.minimumMacOSVersion)

    let wine = try containedURL(manifest.wine, root: root)
    let wineLoader = try containedURL(manifest.wineLoader, root: root)
    let server = try containedURL(manifest.wineserver, root: root)
    let driver = try containedURL(manifest.macDriver, root: root)
    let windowsRuntime = try containedURL(manifest.windowsRuntime, root: root)
    let direct3D9 = try manifest.direct3D9.map { try containedURL($0, root: root) }
    let vulkanLibrary = try manifest.vulkanLibrary.map { try containedURL($0, root: root) }

    // DXVK and MoltenVK form one backend; either both are present or WineD3D is used.
    guard (direct3D9 == nil) == (vulkanLibrary == nil) else {
      throw ApplicationError(message: "The Metal runtime needs both DXVK and MoltenVK.")
    }
    if let direct3D9, let vulkanLibrary {
      guard try BinaryArchitecture.peMachine(direct3D9) == architecture.peMachine,
        try BinaryArchitecture.containsMachO(vulkanLibrary, architecture: architecture) else {
        throw ApplicationError(message: "The Metal runtime must contain native \(architecture.rawValue) graphics libraries.")
      }
    }

    let archiver = wine.deletingLastPathComponent().appendingPathComponent("7zz")
    for executable in [wine, wineLoader, server, archiver] {
      guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw ApplicationError(message: "Runtime executable is missing or not executable: \(executable.lastPathComponent)")
      }
    }

    for nativeFile in [wine, wineLoader, server, driver, archiver] {
      guard try BinaryArchitecture.containsMachO(nativeFile, architecture: architecture) else {
        throw ApplicationError(message: "\(nativeFile.lastPathComponent) must contain \(architecture.rawValue) macOS code.")
      }
    }
    guard try BinaryArchitecture.peMachine(windowsRuntime) == architecture.peMachine else {
      throw ApplicationError(message: "\(windowsRuntime.lastPathComponent) must be a \(architecture.rawValue) Windows binary.")
    }

    return WineRuntime(
      architecture: architecture, prefix: prefix, wine: wine, wineLoader: wineLoader, wineserver: server,
      archiver: archiver, direct3D9: direct3D9
    )
  }

  var frameworkDirectory: URL {
    prefix.appendingPathComponent("drive_c/windows/Microsoft.NET/\(architecture.frameworkFolder)/v4.0.30319")
  }

  var windowsFrameworkDirectory: String {
    "C:\\windows\\Microsoft.NET\\\(architecture.frameworkFolder)\\v4.0.30319"
  }

  func validateFramework() throws {
    guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) else {
      throw ApplicationError(message: "The Wine prefix has not been initialized.")
    }

    for name in ["clr.dll", "clrjit.dll"] {
      guard try BinaryArchitecture.peMachine(frameworkDirectory.appendingPathComponent(name)) == architecture.peMachine else {
        throw ApplicationError(message: "The prefix needs \(architecture.rawValue) .NET Framework 4.8.1 (\(name)).")
      }
    }
  }

  // A runtime may require a newer OS than the app deployment target.
  private static func validateMacOSVersion(_ version: String?) throws {
    guard let version else { return }

    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    let numbers = parts.compactMap { Int($0) }
    guard (2...3).contains(parts.count), numbers.count == parts.count,
      parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
      numbers[0] > 0 else {
      throw ApplicationError(message: "Invalid runtime minimumMacOSVersion: \(version). Use major.minor or major.minor.patch.")
    }

    let minimum = OperatingSystemVersion(
      majorVersion: numbers[0], minorVersion: numbers[1],
      patchVersion: numbers.count == 3 ? numbers[2] : 0
    )
    guard ProcessInfo.processInfo.isOperatingSystemAtLeast(minimum) else {
      throw ApplicationError(message: "The selected runtime requires macOS \(version) or later. This Mac runs macOS \(ProcessInfo.processInfo.operatingSystemVersionString).")
    }
  }

  private static func containedURL(_ relative: String, root: URL) throws -> URL {
    // Resolve symlinks before checking containment, not just relative path components.
    let base = root.resolvingSymlinksInPath().standardizedFileURL
    let result = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
    guard !relative.hasPrefix("/"), result.path.hasPrefix(base.path + "/") else {
      throw ApplicationError(message: "Runtime manifest paths must stay inside the runtime directory.")
    }

    return result
  }

  func preparePrefix() throws {
    let files = FileManager.default
    let profile = prefix.appendingPathComponent("drive_c/users/\(NSUserName())", isDirectory: true)
    let desktop = profile.appendingPathComponent("Desktop", isDirectory: true)

    let previousDesktop: URL?
    if (try? files.destinationOfSymbolicLink(atPath: desktop.path)) != nil {
      previousDesktop = desktop.resolvingSymlinksInPath()
      try files.removeItem(at: desktop)
    } else {
      previousDesktop = nil
    }

    // An existing directory keeps Wine from linking this folder to the Mac desktop.
    try files.createDirectory(at: desktop, withIntermediateDirectories: true)

    guard let previousDesktop, previousDesktop != desktop else { return }

    // Migrate only a shortcut that matches this prefix's installed ClickOnce reference.
    let name = "Magic The Gathering Online .appref-ms"
    let reference = profile.appendingPathComponent("AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Daybreak Game Company LLC/\(name)")
    let shortcut = previousDesktop.appendingPathComponent(name)
    guard let installed = try? Data(contentsOf: reference), !installed.isEmpty,
      (try? Data(contentsOf: shortcut)) == installed else { return }

    let destination = desktop.appendingPathComponent(name)
    do {
      if !files.fileExists(atPath: destination.path) {
        try files.moveItem(at: shortcut, to: destination)
      } else if (try? Data(contentsOf: destination)) == installed {
        try files.removeItem(at: shortcut)
      }
    } catch {
      NSLog("Could not move MTGO's desktop shortcut: %@", error.localizedDescription)
    }
  }

  func prepareGraphics() throws {
    guard let direct3D9 else { return }

    let files = FileManager.default
    let destination = prefix.appendingPathComponent("drive_c/windows/system32/d3d9.dll")
    guard !files.contentsEqual(atPath: direct3D9.path, andPath: destination.path) else { return }

    // Stage beside the destination so an existing DLL can be replaced atomically.
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".d3d9-\(UUID().uuidString).dll")
    defer { try? files.removeItem(at: temporary) }
    try files.copyItem(at: direct3D9, to: temporary)
    if files.fileExists(atPath: destination.path) {
      // Copying old extended attributes onto a read-only replacement can fail.
      _ = try files.replaceItemAt(destination, withItemAt: temporary, options: .usingNewMetadataOnly)
    } else {
      try files.moveItem(at: temporary, to: destination)
    }
  }

  func startupRegistry(softwareRendering: Bool, icon: URL?) -> Data {
    var registry = WineRegistry()
    registry.addKey("HKEY_CURRENT_USER\\Software\\Wine\\Drivers", values: [
      .init(name: "Graphics", value: .string("mac")),
    ])
    registry.addKey("HKEY_CURRENT_USER\\Software\\Microsoft\\Avalon.Graphics", values: [
      .init(name: "DisableHWAcceleration", value: .dword(softwareRendering ? 1 : 0)),
    ])

    // Splash suppression and main-window detection apply only to MTGO.
    registry.addKey("HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\MTGO.exe\\Mac Driver", values: [
      .init(name: "SkipWindowTitle", value: .string("KickerWindow")),
      .init(name: "MainWindowTitle", value: .string("Magic: The Gathering Online")),
    ])

    // Wine helpers use the same branding as the game.
    if let icon {
      registry.addKey("HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver", values: [
        .init(name: "ApplicationIcon", value: .string(icon.path)),
      ])
    }

    return registry.data
  }

  var environment: [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["WINEPREFIX"] = prefix.path
    env["WINE_DOCK_OWNER_PID"] = String(ProcessInfo.processInfo.processIdentifier)
    env["WINE_DOCK_STARTUP_TRANSITION"] = "1"
    env["WINEARCH"] = "win64"
    env["WINEDEBUG"] = env["MTGO_WINEDEBUG"] ?? "-all"

    let binaries = wine.deletingLastPathComponent()
    env["DYLD_FALLBACK_LIBRARY_PATH"] = binaries.deletingLastPathComponent().appendingPathComponent("lib").path + ":/usr/lib"
    env["WINEDLLOVERRIDES"] = direct3D9 == nil ? "winemenubuilder.exe=" : "winemenubuilder.exe=;d3d9=n"
    env["PATH"] = binaries.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")

    // The macOS driver supplies windows directly; no XQuartz or VNC display.
    env.removeValue(forKey: "DISPLAY")
    env.removeValue(forKey: "WAYLAND_DISPLAY")
    env.removeValue(forKey: "HODLL")
    env.removeValue(forKey: "HODLL64")

    return env
  }
}
