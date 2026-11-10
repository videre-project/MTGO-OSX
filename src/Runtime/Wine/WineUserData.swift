import Darwin
import Foundation

/// Keeps ClickOnce's data path intact while storing its files in a chosen folder.
struct WineUserData {
  let prefix: URL
  private let files = FileManager.default

  static func directory(in prefix: URL) -> URL {
    prefix.appendingPathComponent("drive_c/users/\(NSUserName())/AppData/Local/Apps/2.0/Data", isDirectory: true)
  }

  static func validate(_ folder: URL, for prefix: URL) throws {
    let destination = canonicalPath(folder)
    let installation = canonicalPath(prefix)
    guard !overlaps(destination, installation) else {
      throw ApplicationError(message: "Choose a user data folder outside the Wine prefix.")
    }
  }

  /// Applies a folder change while Wine is stopped; returns whether the data path changed.
  @discardableResult
  func prepare(folder: URL?, preparing: @MainActor @Sendable () -> Void = {}) async throws -> Bool {
    try Task.checkCancellation()
    let path = Self.directory(in: prefix)
    let isLink = (try? files.destinationOfSymbolicLink(atPath: path.path)) != nil
    let exists = isLink || files.fileExists(atPath: path.path)
    guard folder != nil || isLink else { return false }

    let source = path.resolvingSymlinksInPath().standardizedFileURL
    if exists { try requireDirectory(source) }
    try files.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

    // Reset copies data back into the prefix; the external folder stays intact.
    guard let folder else {
      let localPath = path.deletingLastPathComponent().resolvingSymlinksInPath()
        .appendingPathComponent(path.lastPathComponent).path
      guard !Self.overlaps(source.path, localPath) else {
        throw ApplicationError(message: "The existing data link contains its own Wine path. Move the data to a separate folder before resetting it.")
      }
      await preparing()
      let staged = temporary(beside: path)
      defer { try? files.removeItem(at: staged) }
      try files.copyItem(at: source, to: staged)
      try Task.checkCancellation()
      try replaceDataPath(staged, at: path)
      return true
    }

    try Self.validate(folder, for: prefix)
    let destination = folder.resolvingSymlinksInPath().standardizedFileURL
    try requireDirectory(destination)
    guard files.isWritableFile(atPath: destination.path) else {
      throw ApplicationError(message: "The MTGO user data folder is not writable: \(folder.path)")
    }
    if isLink && source.path == destination.path { return false }
    guard !exists || !Self.overlaps(source.path, destination.path) else {
      throw ApplicationError(message: "Choose a folder separate from the current MTGO user data folder.")
    }

    await preparing()

    // A completed copy may remain if an earlier attempt stopped before replacing the link.
    if exists, try !isEmpty(source), !files.contentsEqual(atPath: source.path, andPath: destination.path) {
      guard try isEmpty(destination) else {
        throw ApplicationError(message: "The current and selected folders both contain files. Choose an empty destination to preserve both sets of data.")
      }

      // Stage on the destination volume, so migration also works across disks.
      let staged = temporary(beside: destination)
      defer { try? files.removeItem(at: staged) }
      try files.copyItem(at: source, to: staged)
      try Task.checkCancellation()
      try installCopy(staged, at: destination)
    }

    let staged = temporary(beside: path)
    defer { try? files.removeItem(at: staged) }
    try files.createSymbolicLink(at: staged, withDestinationURL: destination)
    try Task.checkCancellation()
    try replaceDataPath(staged, at: path)
    return true
  }

  private func requireDirectory(_ path: URL) throws {
    var directory: ObjCBool = false
    guard files.fileExists(atPath: path.path, isDirectory: &directory), directory.boolValue else {
      throw ApplicationError(message: "The MTGO user data folder is unavailable: \(path.path). Reconnect it or choose another folder in Settings.")
    }
  }

  private func isEmpty(_ directory: URL) throws -> Bool {
    let names = try files.contentsOfDirectory(atPath: directory.path)
    if names.isEmpty { return true }
    guard names == [".DS_Store"] else { return false }
    return try files.attributesOfItem(atPath: directory.appendingPathComponent(".DS_Store").path)[.type]
      as? FileAttributeType == .typeRegular
  }

  private func temporary(beside path: URL) -> URL {
    path.deletingLastPathComponent().appendingPathComponent(".mtgo-data-\(UUID().uuidString)")
  }

  private func replaceDataPath(_ staged: URL, at path: URL) throws {
    let exists = files.fileExists(atPath: path.path)
      || (try? files.destinationOfSymbolicLink(atPath: path.path)) != nil

    // Swapping permits a directory and a symlink to exchange places without a gap.
    let flags = exists ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
    guard renamex_np(staged.path, path.path, flags) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private func installCopy(_ staged: URL, at path: URL) throws {
    let metadata = path.appendingPathComponent(".DS_Store")
    if files.fileExists(atPath: metadata.path) { try files.removeItem(at: metadata) }

    // Ordinary directory replacement fails if another writer populated the destination.
    // It also works on destination volumes that do not support directory swaps.
    guard rename(staged.path, path.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private static func overlaps(_ first: String, _ second: String) -> Bool {
    first == second || first.hasPrefix(second == "/" ? "/" : second + "/")
      || second.hasPrefix(first == "/" ? "/" : first + "/")
  }

  private static func canonicalPath(_ path: URL) -> String {
    var parent = path.standardizedFileURL
    var missing: [String] = []

    // Foundation resolves /var and /private/var differently for nonexistent paths.
    // Resolve an existing parent first, then append any missing components.
    while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
      missing.append(parent.lastPathComponent)
      parent.deleteLastPathComponent()
    }

    var resolved = parent.resolvingSymlinksInPath().standardizedFileURL
    for component in missing.reversed() { resolved.appendPathComponent(component) }
    return resolved.path
  }
}
