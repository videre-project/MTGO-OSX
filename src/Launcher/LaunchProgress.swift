import Foundation

/// Progress records emitted by MTGOSDK's ClickOnce launcher.
struct LaunchProgress: Decodable, Equatable {
  // Values match MTGOSDK.Core.Remoting.LaunchStage.
  enum Stage: Int, Decodable {
    case checkingForUpdates = 0
    case verifyingRequirements = 1
    case downloading = 2
    case updateCompleted = 3
    case starting = 4
    case started = 5
    case failed = 6
  }

  let stage: Stage
  let percentage: Int?
  let bytesDownloaded: Int64?
  let totalBytes: Int64?
  let version: String?
  let message: String?

  static func decode(_ line: String) -> LaunchProgress? {
    // Wine and the SDK share stdout; only JSON records represent launcher progress.
    guard line.hasPrefix("{"), let data = line.data(using: .utf8) else { return nil }

    return try? JSONDecoder().decode(Self.self, from: data)
  }

  var title: String {
    switch stage {
    case .checkingForUpdates:
      return "Checking for MTGO updates…"
    case .verifyingRequirements:
      return "Checking application requirements…"
    case .downloading:
      return "Downloading MTGO…"
    case .updateCompleted:
      return "MTGO is up to date."
    case .starting:
      return "Starting MTGO…"
    case .started:
      return "MTGO is running."
    case .failed:
      return "MTGO could not be started."
    }
  }
}
