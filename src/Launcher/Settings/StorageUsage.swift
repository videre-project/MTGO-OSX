import Foundation

enum StorageUsage {
  // Async work runs off the main actor; cancellation stops scans after a folder changes.
  nonisolated static func size(of directory: URL) async -> Int64? {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey]
    guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
    guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return nil }

    var total: Int64 = 0
    for case let file as URL in files {
      if Task.isCancelled { return nil }
      guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }

      // Wine prefixes include links to host folders and drives; count only their own files.
      if values.isSymbolicLink == true {
        files.skipDescendants()
      } else if values.isRegularFile == true {
        total += Int64(values.totalFileAllocatedSize ?? 0)
      }
    }
    return total
  }
}
