import CryptoKit
import Foundation

/// Reuses a cached package only when its SHA-256 matches the pinned payload.
struct VerifiedDownload {
  let url: URL
  let sha256: String

  func fetch(
    to destination: URL,
    progress: (@MainActor @Sendable (Int64, Int64) -> Void)? = nil
  ) async throws {
    try Task.checkCancellation()

    let files = FileManager.default
    if files.fileExists(atPath: destination.path), try digest(destination) == sha256 {
      return
    }

    let delegate = progress.map { DownloadProgress(report: $0) }
    let (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
    defer { try? files.removeItem(at: temporary) }
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw ApplicationError(message: "Download failed: \(url.lastPathComponent)")
    }

    guard try digest(temporary) == sha256 else {
      throw ApplicationError(message: "SHA-256 mismatch for \(url.lastPathComponent).")
    }

    try Task.checkCancellation()

    // Copy to the cache volume before replacing an existing entry atomically.
    let staged = destination.deletingLastPathComponent()
      .appendingPathComponent(".download-\(UUID().uuidString)")
    defer { try? files.removeItem(at: staged) }
    try files.copyItem(at: temporary, to: staged)
    if files.fileExists(atPath: destination.path) {
      _ = try files.replaceItemAt(destination, withItemAt: staged)
    } else {
      try files.moveItem(at: staged, to: destination)
    }
  }

  private func digest(_ file: URL) throws -> String {
    let data = try Data(contentsOf: file, options: .mappedIfSafe)

    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

/// Forwards byte counts without buffering the downloaded archive in memory.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
  private let report: @MainActor @Sendable (Int64, Int64) -> Void
  private var lastReport: TimeInterval = 0

  init(report: @escaping @MainActor @Sendable (Int64, Int64) -> Void) {
    self.report = report
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastReport >= 0.1 || totalBytesWritten == totalBytesExpectedToWrite else { return }

    lastReport = now
    DispatchQueue.main.async { [report] in report(totalBytesWritten, totalBytesExpectedToWrite) }
  }

  // fetch receives the temporary file from URLSession's async download call.
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
