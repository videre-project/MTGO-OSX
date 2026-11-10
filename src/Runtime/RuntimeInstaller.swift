import CoreServices
import Foundation

/// Downloads, verifies and installs the native Wine runtime.
actor RuntimeInstaller {
  enum Progress: Sendable {
    case downloading, transferring(Int64, Int64), installing(Int, Int), installed
  }

  private let package: RuntimePackage
  private let directory: URL
  private let cache: URL
  private let log: URL
  private let progress: @MainActor @Sendable (Progress) -> Void

  init(
    package: RuntimePackage, directory: URL, cache: URL, log: URL,
    progress: @escaping @MainActor @Sendable (Progress) -> Void
  ) {
    self.package = package
    self.directory = directory
    self.cache = cache
    self.log = log
    self.progress = progress
  }

  func installIfNeeded(prefix: URL) async throws -> URL {
    let files = FileManager.default
    let destination = package.installationDirectory(in: directory)
    if isInstalled(at: destination, prefix: prefix) {
      try register(at: destination)
      return destination
    }

    try files.createDirectory(at: cache, withIntermediateDirectories: true)
    try files.createDirectory(at: directory, withIntermediateDirectories: true)

    await progress(.downloading)
    let archive = cache.appendingPathComponent("runtime-\(package.sha256).tar.xz")
    try await VerifiedDownload(url: package.url, sha256: package.sha256).fetch(to: archive) { [progress] bytes, total in
      progress(.transferring(bytes, total))
    }

    // Extract on the installation volume so the validated directory can be moved atomically.
    await progress(.installing(0, 3))
    let staging = directory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
    try files.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: staging) }

    try await NativeProcess.run(
      URL(fileURLWithPath: "/usr/bin/tar"), ["-xJf", archive.path, "-C", staging.path], log: log
    )
    await progress(.installing(1, 3))
    _ = try WineRuntime.load(root: staging, prefix: prefix)
    try await NativeProcess.run(
      URL(fileURLWithPath: "/usr/bin/codesign"),
      ["--verify", "--deep", "--strict", staging.appendingPathComponent("MTGO.app").path], log: log
    )
    try package.sha256.write(to: staging.appendingPathComponent(".archive.sha256"), atomically: true, encoding: .utf8)
    try Task.checkCancellation()
    await progress(.installing(2, 3))

    // Another launcher instance may have installed this release while the download was running.
    if !isInstalled(at: destination, prefix: prefix) {
      try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      do {
        if files.fileExists(atPath: destination.path) {
          _ = try files.replaceItemAt(destination, withItemAt: staging)
        } else {
          try files.moveItem(at: staging, to: destination)
        }
      } catch {
        guard isInstalled(at: destination, prefix: prefix) else { throw error }
      }
    }

    try register(at: destination)
    await progress(.installing(3, 3))
    await progress(.installed)
    return destination
  }

  private func isInstalled(at root: URL, prefix: URL) -> Bool {
    (try? String(contentsOf: root.appendingPathComponent(".archive.sha256"), encoding: .utf8)) == package.sha256
      && (try? WineRuntime.load(root: root, prefix: prefix)) != nil
  }

  private func register(at root: URL) throws {
    // Downloaded helpers live outside Applications; register their final bundle location.
    let app = root.appendingPathComponent("MTGO.app")
    let status = LSRegisterURL(app as CFURL, false)
    guard status == noErr else {
      throw ApplicationError(message: "Could not register MTGO's runtime with macOS (\(status)).")
    }
  }
}
