import Darwin
import Foundation

/// Filesystem checks for runtime preparation and installation progress.
@main
@MainActor
enum PreparationTests {
  static func main() async {
    do {
      let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEST_TMPDIR"] ?? NSTemporaryDirectory())
        .appendingPathComponent("preparation-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      for architecture in [RuntimeArchitecture.arm64, .x86_64] {
        try await componentsReportInstalledFiles(in: root, architecture: architecture)
      }
      try readOnlyGraphicsLibraryReplacesExistingMetadata(in: root)
      try await failedComponentsDoNotReportCompletion(in: root)
      try await UserDataTests.run(in: root)
      print("PASS: Framework component progress follows installed files on ARM64 and Intel; failed components do not advance it.")
    } catch {
      fputs("FAIL: \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }

  private static func componentsReportInstalledFiles(in root: URL, architecture: RuntimeArchitecture) async throws {
    let components = root.appendingPathComponent(architecture.rawValue)
    let drive = root.appendingPathComponent("drive-\(architecture.rawValue)")
    try writeComponent("First", in: components, architecture: architecture)
    try writeComponent("Second", in: components, architecture: architecture)
    let installer = FrameworkComponents(directory: components, driveC: drive, architecture: architecture)
    var reports: [StartupProgress] = []
    var installedAtReport: [Bool] = []

    _ = try await installer.install { completed, total in
      reports.append(.components(completed: completed, total: total))
      if completed > 0 {
        let name = completed == 1 ? "First" : "Second"
        let destination = drive.appendingPathComponent("windows/Microsoft.NET/\(architecture.frameworkFolder)/v4.0.30319/\(name).dll")
        installedAtReport.append((try? String(contentsOf: destination)) == name)
      }
    }

    try require(reports.count == 3 && reports.first?.fraction == 0 && reports.last?.fraction == 1,
      "Component progress must begin empty and finish after both components")
    try require(installedAtReport == [true, true], "A component must exist before its completion is reported")
    try require(reports[1].detail == "1 of 2 components", "The launcher must display the measured component count")
  }

  private static func failedComponentsDoNotReportCompletion(in root: URL) async throws {
    let components = root.appendingPathComponent("invalid")
    try writeComponent("First", in: components, architecture: .arm64)
    try "<assembly/>".write(to: components.appendingPathComponent("arm64_Second.manifest"), atomically: true, encoding: .utf8)
    let installer = FrameworkComponents(directory: components, driveC: root.appendingPathComponent("invalid-drive"), architecture: .arm64)
    var completed: [Int] = []
    do {
      _ = try await installer.install { count, _ in completed.append(count) }
      throw failure("A malformed component must fail installation")
    } catch is ApplicationError {
      try require(completed == [0, 1], "A failed component must not advance progress or report 100 percent")
    }
  }

  private static func readOnlyGraphicsLibraryReplacesExistingMetadata(in root: URL) throws {
    let files = FileManager.default
    let source = root.appendingPathComponent("packaged-d3d9.dll")
    try Data("Packaged DXVK".utf8).write(to: source)
    try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: source.path)

    let prefix = root.appendingPathComponent("graphics-prefix")
    let system32 = prefix.appendingPathComponent("drive_c/windows/system32")
    let destination = system32.appendingPathComponent("d3d9.dll")
    try files.createDirectory(at: system32, withIntermediateDirectories: true)
    try Data("Previous DLL".utf8).write(to: destination)

    // Existing prefix files can have extended attributes even when their contents are writable.
    let attribute = "org.videreproject.MTGOOSX.test"
    var value: UInt8 = 1
    guard setxattr(destination.path, attribute, &value, 1, 0, 0) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    let runtime = WineRuntime(
      architecture: .native, prefix: prefix, wine: root, wineLoader: root,
      wineserver: root, archiver: root, direct3D9: source
    )
    try runtime.prepareGraphics()
    try require(try Data(contentsOf: destination) == Data("Packaged DXVK".utf8),
      "Graphics preparation must replace an existing DLL with the packaged bytes")
    try require(getxattr(destination.path, attribute, nil, 0, 0, 0) == -1 && errno == ENOATTR,
      "A replacement DLL must not inherit obsolete extended attributes")
    try require(try Data(contentsOf: source) == Data("Packaged DXVK".utf8)
      && (try files.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber)?.intValue == 0o555,
      "Graphics preparation must preserve packaged bytes and read-only permissions")

    let fileNumber = try files.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? NSNumber
    try runtime.prepareGraphics()
    try require(fileNumber != nil && (try files.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? NSNumber) == fileNumber,
      "A matching graphics DLL must be reused on subsequent launches")
    try require(try files.contentsOfDirectory(atPath: system32.path) == ["d3d9.dll"],
      "Graphics preparation must remove temporary replacement files")
    print("PASS: read-only graphics libraries replace existing DLL metadata and are reused unchanged.")
  }

  private static func writeComponent(_ name: String, in directory: URL, architecture: RuntimeArchitecture) throws {
    let component = directory.appendingPathComponent("\(architecture.componentName)_\(name)")
    try FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
    try name.write(to: component.appendingPathComponent(name + ".dll"), atomically: true, encoding: .utf8)
    try """
      <assembly>
        <assemblyIdentity publicKeyToken="test" />
        <file name="\(name).dll" destinationPath="$(runtime.windows)/Microsoft.NET/\(architecture.frameworkFolder)/v4.0.30319/" />
      </assembly>
      """.write(to: component.appendingPathExtension("manifest"), atomically: true, encoding: .utf8)
  }

  private static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw failure(message) }
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "PreparationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
