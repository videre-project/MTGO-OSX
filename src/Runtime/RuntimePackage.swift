import Foundation

/// A pinned runtime release for one native macOS architecture.
struct RuntimePackage: Decodable {
  let version: String
  let architecture: String
  let url: URL
  let sha256: String

  static var nativeArchitecture: String { RuntimeArchitecture.native.rawValue }

  static func load(catalog: URL) throws -> RuntimePackage {
    struct Catalog: Decodable {
      let schemaVersion: Int
      let packages: [RuntimePackage]
    }

    let data = try Data(contentsOf: catalog)
    let catalog = try JSONDecoder().decode(Catalog.self, from: data)
    guard catalog.schemaVersion == 1 else {
      throw ApplicationError(message: "The runtime catalog is incompatible with this launcher.")
    }

    let matches = catalog.packages.filter { $0.architecture == nativeArchitecture }
    guard matches.count == 1, let package = matches.first else {
      throw ApplicationError(message: "This build does not include a runtime release for \(nativeArchitecture) Macs.")
    }

    // Version identifiers become directory names; checksums identify immutable payloads.
    let identifiers = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
    guard !package.version.isEmpty, package.version != ".", package.version != "..",
      package.version.unicodeScalars.allSatisfy(identifiers.contains),
      package.sha256.count == 64,
      package.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw ApplicationError(message: "The runtime catalog contains an invalid version or checksum.")
    }

    // Local HTTP is reserved for integration fixtures; release downloads use HTTPS.
    let loopback = ["127.0.0.1", "localhost", "[::1]"].contains(package.url.host ?? "")
    guard package.url.scheme == "https" || (package.url.scheme == "http" && loopback) else {
      throw ApplicationError(message: "Runtime releases must be downloaded over HTTPS.")
    }

    return package
  }

  func installationDirectory(in root: URL) -> URL {
    root.appendingPathComponent(version, isDirectory: true)
      .appendingPathComponent(architecture, isDirectory: true)
  }
}
