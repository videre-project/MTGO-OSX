import Foundation

struct MTGOManifest: Decodable {
  let version: String

  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    // Bound the entire lookup so an unavailable API does not hold up a cached launch.
    configuration.timeoutIntervalForResource = 3

    return URLSession(configuration: configuration)
  }()

  /// Retrieves the current MTGO version for the SDK launcher's update check.
  static func fetch() async throws -> MTGOManifest {
    let address = ProcessInfo.processInfo.environment["MTGO_MANIFEST_URL"]
      ?? "https://api.videreproject.com/mtgo/manifest"
    guard let url = URL(string: address), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
      throw ApplicationError(message: "The MTGO manifest URL must use HTTP or HTTPS.")
    }

    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.timeoutInterval = 3

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    request.setValue("MTGO-OSX/\(version)", forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
      throw ApplicationError(message: "Could not retrieve the MTGO manifest.")
    }

    // Validate the version before forwarding it to the SDK launcher.
    let manifest = try JSONDecoder().decode(MTGOManifest.self, from: data)
    let components = manifest.version.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 4, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && UInt16($0) != nil }) else {
      throw ApplicationError(message: "The MTGO manifest has an invalid version.")
    }

    return manifest
  }
}
