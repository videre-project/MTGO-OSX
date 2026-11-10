import Foundation

/// Prepares Wine's prefix and installs the verified native .NET Framework payload.
actor FrameworkInstaller {
  enum Progress: Sendable {
    case preparing, downloading, unpacking, installing, configuring, installed
    case transferring(Int64, Int64), components(Int, Int)
    case optimizing, assembly(String), optimized, optimizationFailed(String)
  }

  private struct ActivationLibrary {
    let name: String
    let download: VerifiedDownload
  }

  private static let package = VerifiedDownload(
    url: URL(string: "https://download.microsoft.com/download/4/b/2/cd00d4ed-ebdd-49ee-8a33-eabc3d1030e3/NDP481-x86-x64-AllOS-ENU.exe")!,
    sha256: "c0ca2e0c9cd18a24a0a77369a13fae2c2c4e8bc83355dd24e5ddc00f9d791fe3"
  )
  private static let arm64ActivationLibraries = [
    ActivationLibrary(name: "mscoree.dll", download: VerifiedDownload(
      url: URL(string: "https://msdl.microsoft.com/download/symbols/mscoree.dll/3E10D7C2cd000/mscoree.dll")!,
      sha256: "39578634ab8e0059ff50bd34117f1eedfe4efa313f9df266fe738a4e0eef0e27"
    )),
    ActivationLibrary(name: "dfshim.dll", download: VerifiedDownload(
      url: URL(string: "https://msdl.microsoft.com/download/symbols/dfshim.dll/3576AA6935e000/dfshim.dll")!,
      sha256: "67999b88c749510eb59c9ad625ba70a9bd20e0ef50d75fade21f3ccd591b9754"
    )),
  ]

  private static let x64ActivationLibraries = [
    ActivationLibrary(name: "mscoree.dll", download: VerifiedDownload(
      url: URL(string: "https://msdl.microsoft.com/download/symbols/mscoree.dll/51BD878B65000/mscoree.dll")!,
      sha256: "7ac7e873d3b291fcd33744131598929374d9a17498f7db1eafec29d25d053e18"
    )),
    ActivationLibrary(name: "dfshim.dll", download: VerifiedDownload(
      url: URL(string: "https://msdl.microsoft.com/download/symbols/dfshim.dll/2E2B80CD188000/dfshim.dll")!,
      sha256: "63975e8a179027a803e2d5165dfc5de59abd2ab6179b99d814fb7223687dad49"
    )),
  ]

  private var activationLibraries: [ActivationLibrary] {
    runtime.architecture == .arm64 ? Self.arm64ActivationLibraries : Self.x64ActivationLibraries
  }

  private let runtime: WineRuntime
  private let cache: URL
  private let log: URL
  private let progress: @MainActor @Sendable (Progress) -> Void
  private let files = FileManager.default

  init(runtime: WineRuntime, cache: URL, log: URL, progress: @escaping @MainActor @Sendable (Progress) -> Void) {
    self.runtime = runtime
    self.cache = cache
    self.log = log
    self.progress = progress
  }

  func installIfNeeded(bootstrapRegistry: Data) async throws {
    try files.createDirectory(at: cache, withIntermediateDirectories: true)
    try runtime.preparePrefix()

    let preparing = !isPrepared
    if preparing { await progress(.preparing) }

    // Apply current settings even when the Framework payload is already installed.
    try await bootstrapPrefix(registry: bootstrapRegistry)
    if !isPrepared {
      try await installPayload()
    }

    try runtime.prepareGraphics()
    try FrameworkConfiguration(directory: runtime.frameworkDirectory).enableNativeSHA256()
    if preparing { await progress(.installed) }

    try await prepareNativeImagesIfNeeded()
  }

  private var marker: URL {
    runtime.prefix.appendingPathComponent(".mtgo-framework.sha256")
  }

  private var isPrepared: Bool {
    let typeLibrary = runtime.prefix.appendingPathComponent(
      "drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/mscoree.tlb"
    )

    // The marker alone is insufficient if installation files were removed or replaced.
    return (try? String(contentsOf: marker, encoding: .utf8)) == Self.package.sha256
      && files.fileExists(atPath: typeLibrary.path)
      && (try? runtime.validateFramework()) != nil
  }

  private func bootstrapPrefix(registry: Data) async throws {
    var environment = runtime.environment
    environment["WINEDLLOVERRIDES"] = "mscoree,mshtml,winemenubuilder.exe="

    let registryFile = runtime.prefix.appendingPathComponent(".mtgo-bootstrap-\(UUID().uuidString).reg")
    defer { try? files.removeItem(at: registryFile) }
    try registry.write(to: registryFile, options: .atomic)

    let arguments = ["reg", "import", registryFile.path]
    // This command lets Wine service the prefix with CLR registration disabled.
    // Explicit wineboot --init would start a second service manager.
    try await NativeProcess.run(runtime.wine, arguments, environment: environment, log: log)
  }

  private func installPayload() async throws {
    // Release Wine's loaded CLR and registry files before replacing the payload.
    try await wineServer("-k")
    try await wineServer("-w")

    let package = cache.appendingPathComponent("NDP481.exe")
    await progress(.downloading)
    try await Self.package.fetch(to: package) { [progress] bytes, total in
      progress(.transferring(bytes, total))
    }

    let scratch = cache.appendingPathComponent("framework-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: scratch) }

    let components = try await unpack(package, into: scratch)
    let driveC = runtime.prefix.appendingPathComponent("drive_c", isDirectory: true)
    guard files.fileExists(atPath: driveC.path) else {
      throw ApplicationError(message: "Wine did not initialize the prefix.")
    }

    await progress(.installing)
    let registration = try await FrameworkComponents(directory: components, driveC: driveC, architecture: runtime.architecture)
      .install { [progress] completed, total in progress(.components(completed, total)) }
    try await installActivationLibraries(in: driveC)

    let registry = scratch.appendingPathComponent("framework.reg")
    try registration.data.write(to: registry, options: .atomic)

    await progress(.configuring)
    try await configureActivation(registry: registry)
    try runtime.validateFramework()

    // Mark installation complete only after activation and architecture validation.
    try Self.package.sha256.write(to: marker, atomically: true, encoding: .utf8)
  }

  private func unpack(_ package: URL, into scratch: URL) async throws -> URL {
    await progress(.unpacking)
    let cabName = runtime.architecture == .arm64
      ? "xarm64-Windows10.0-KB5011048-arm64.cab" : "x64-Windows10.0-KB5011048-x64.cab"
    try await NativeProcess.run(
      runtime.archiver, ["e", "-y", "-o\(scratch.path)", package.path, cabName], log: log
    )

    let components = scratch.appendingPathComponent("components", isDirectory: true)
    try await NativeProcess.run(
      runtime.archiver,
      ["x", "-y", "-o\(components.path)", scratch.appendingPathComponent(cabName).path], log: log
    )

    return components
  }

  private func installActivationLibraries(in driveC: URL) async throws {
    let system32 = driveC.appendingPathComponent("windows/system32", isDirectory: true)
    let libraryCache = cache.appendingPathComponent(runtime.architecture.rawValue, isDirectory: true)
    try files.createDirectory(at: libraryCache, withIntermediateDirectories: true)
    for library in activationLibraries {
      let cached = libraryCache.appendingPathComponent(library.name)
      await progress(.downloading)
      try await library.download.fetch(to: cached) { [progress] bytes, total in
        progress(.transferring(bytes, total))
      }

      let destination = system32.appendingPathComponent(library.name)
      if files.fileExists(atPath: destination.path) {
        try files.removeItem(at: destination)
      }
      try files.copyItem(at: cached, to: destination)
    }
  }

  private func configureActivation(registry: URL) async throws {
    try await wine(["reg", "import", registry.path])

    let roots = runtime.architecture == .arm64 ? ["InstallRoot", "InstallRootArm64"] : ["InstallRoot"]
    for name in roots {
      try await wine([
        "reg", "add", "HKLM\\Software\\Microsoft\\.NETFramework", "/v", name,
        "/t", "REG_SZ", "/d", "C:\\windows\\Microsoft.NET\\\(runtime.architecture.frameworkFolder)\\", "/f",
      ])
    }

    for library in activationLibraries {
      try await wine([
        "reg", "add", "HKCU\\Software\\Wine\\DllOverrides", "/v", String(library.name.dropLast(4)),
        "/t", "REG_SZ", "/d", "native", "/f",
      ])
    }

    try await wine(["winecfg", "-v", "win11"])
  }

  private func prepareNativeImagesIfNeeded() async throws {
    let marker = runtime.prefix.appendingPathComponent(".mtgo-native-images.sha256")
    guard (try? String(contentsOf: marker, encoding: .utf8)) != Self.package.sha256 else { return }

    await progress(.optimizing)
    var failure: String?
    do {
      try await NativeProcess.run(runtime.wine, [
        runtime.windowsFrameworkDirectory + "\\ngen.exe", "install",
        runtime.windowsFrameworkDirectory + "\\WPF\\PresentationFramework.dll", "/nologo",
      ], environment: runtime.environment, log: log) { [progress] line in
        if let name = Self.assemblyName(line) { progress(.assembly(name)) }
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      failure = "Native-image compilation failed; MTGO will use JIT compilation."
      NSLog("Native-image compilation failed; MTGO will use JIT compilation: %@", error.localizedDescription)
    }

    // Record the attempt once per package; failed optimization must not delay every launch.
    try Self.package.sha256.write(to: marker, atomically: true, encoding: .utf8)
    try runtime.prepareGraphics()
    if let failure {
      await progress(.optimizationFailed(failure))
    } else {
      await progress(.optimized)
    }
  }

  private static func assemblyName(_ output: String) -> String? {
    var line = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if line.first?.isNumber == true, let separator = line.firstIndex(of: ">"),
      line[..<separator].allSatisfy(\.isNumber) {
      line = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    }

    // NGen reports both newly compiled and previously installed native images.
    for prefix in ["Compiling assembly ", "Installed native image for assembly "] where line.hasPrefix(prefix) {
      let descriptor = String(line.dropFirst(prefix.count))
      let name = descriptor.components(separatedBy: ",")[0].components(separatedBy: " (CLR")[0]
        .replacingOccurrences(of: "\\", with: "/")
        .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
      let filename = (name as NSString).lastPathComponent
      return filename.lowercased().hasSuffix(".dll") ? String(filename.dropLast(4)) : filename
    }

    return nil
  }

  private func wine(_ arguments: [String]) async throws {
    try await NativeProcess.run(runtime.wine, arguments, environment: runtime.environment, log: log)
  }

  private func wineServer(_ argument: String) async throws {
    try await NativeProcess.run(runtime.wineserver, [argument], environment: runtime.environment, log: log)
  }
}
