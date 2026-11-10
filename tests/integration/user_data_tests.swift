import Foundation

/// Filesystem specifications for moving the ClickOnce data store without changing its Wine path.
enum UserDataTests {
  static func run(in root: URL) async throws {
    try await customFolderPreservesPathsAndFiles(in: root)
    try await interruptedCopiesCanBeRetried(in: root)
    try await conflictingFoldersStayUntouched(in: root)
    try await unavailableFoldersDoNotBecomeEmptyStores(in: root)
    try await existingFoldersCanBeAttachedToNewPrefixes(in: root)
    try await resetRejectsRecursiveManualLinks(in: root)
    try recursiveLocationsAreRejected(in: root)
    print("PASS: user data follows the Wine symlink, migration and reset preserve files, and conflicts or unavailable folders fail safely.")
  }

  private static func customFolderPreservesPathsAndFiles(in root: URL) async throws {
    let prefix = root.appendingPathComponent("migration-prefix")
    let original = WineUserData.directory(in: prefix)
    let relative = "FIRST/SECOND/mtgo..tion_test/Data/AppFiles/ACCOUNT/mtgo_game_history"
    try write("history", to: original.appendingPathComponent(relative))
    let desktop = prefix.appendingPathComponent("drive_c/users/\(NSUserName())/Desktop/keep.txt")
    try write("unrelated", to: desktop)
    let destination = root.appendingPathComponent("external-data")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try write("Finder layout", to: destination.appendingPathComponent(".DS_Store"))
    let storage = WineUserData(prefix: prefix)

    try await storage.prepare(folder: destination)
    try require(original.resolvingSymlinksInPath().path == destination.resolvingSymlinksInPath().path,
      "The original Wine data path must resolve to the selected folder")
    try require(try String(contentsOf: original.appendingPathComponent(relative)) == "history",
      "Migration must preserve the full ClickOnce and account directory layout")
    try write("new log", to: original.appendingPathComponent("new-log.dat"))
    try require(try String(contentsOf: destination.appendingPathComponent("new-log.dat")) == "new log",
      "Writes through the Wine path must reach the selected folder")
    let changed = try await storage.prepare(folder: destination)
    try require(!changed, "An unchanged symlink must not recopy the store")

    let nested = destination.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    do {
      try await storage.prepare(folder: nested)
      throw failure("A store must not be copied into itself")
    } catch is ApplicationError {}

    let second = root.appendingPathComponent("second-data")
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try await storage.prepare(folder: second)
    try require(try String(contentsOf: destination.appendingPathComponent(relative)) == "history",
      "Changing folders must retain the previous external copy")
    try await storage.prepare(folder: nil)
    try require((try? FileManager.default.destinationOfSymbolicLink(atPath: original.path)) == nil,
      "Reset must restore a normal directory inside the prefix")
    try require(try String(contentsOf: original.appendingPathComponent("new-log.dat")) == "new log",
      "Reset must retain files written while using the external folder")
    try require(try String(contentsOf: second.appendingPathComponent(relative)) == "history",
      "Reset must not remove the external copy")
    try require(try String(contentsOf: desktop) == "unrelated", "Mapping data must leave the desktop untouched")
  }

  private static func conflictingFoldersStayUntouched(in root: URL) async throws {
    let prefix = root.appendingPathComponent("conflict-prefix")
    let original = WineUserData.directory(in: prefix)
    let destination = root.appendingPathComponent("conflicting-data")
    try write("current", to: original.appendingPathComponent("account/history"))
    try write("other", to: destination.appendingPathComponent("account/history"))
    do {
      try await WineUserData(prefix: prefix).prepare(folder: destination)
      throw failure("Conflicting stores must be rejected")
    } catch is ApplicationError {
      try require(try String(contentsOf: original.appendingPathComponent("account/history")) == "current",
        "A failed migration must preserve the original store")
      try require(try String(contentsOf: destination.appendingPathComponent("account/history")) == "other",
        "A failed migration must not overwrite the selected folder")
    }
  }

  private static func interruptedCopiesCanBeRetried(in root: URL) async throws {
    let prefix = root.appendingPathComponent("retry-prefix")
    let original = WineUserData.directory(in: prefix)
    let destination = root.appendingPathComponent("copied-data")
    try write("history", to: original.appendingPathComponent("account/mtgo_game_history"))

    // Reproduce interruption after the copy completed, before the Wine path changed.
    try FileManager.default.copyItem(at: original, to: destination)
    try await WineUserData(prefix: prefix).prepare(folder: destination)
    try require(original.resolvingSymlinksInPath().path == destination.resolvingSymlinksInPath().path,
      "Retry must attach an unchanged completed copy")
    try require(try String(contentsOf: original.appendingPathComponent("account/mtgo_game_history")) == "history",
      "Recovery must preserve the existing account data")
  }

  private static func unavailableFoldersDoNotBecomeEmptyStores(in root: URL) async throws {
    let prefix = root.appendingPathComponent("offline-prefix")
    let original = WineUserData.directory(in: prefix)
    let destination = root.appendingPathComponent("offline-data")
    let disconnected = root.appendingPathComponent("disconnected-data")
    try write("keep", to: destination.appendingPathComponent("history"))
    let storage = WineUserData(prefix: prefix)
    try await storage.prepare(folder: destination)
    try FileManager.default.moveItem(at: destination, to: disconnected)

    for folder in [destination, nil] as [URL?] {
      do {
        try await storage.prepare(folder: folder)
        throw failure("A missing backing folder must stop both launch and reset")
      } catch is ApplicationError {
        try require((try? FileManager.default.destinationOfSymbolicLink(atPath: original.path)) != nil,
          "A missing backing folder must not replace the existing symlink")
        try require(!FileManager.default.fileExists(atPath: destination.path),
          "An unavailable folder must not be recreated as an empty store")
      }
    }
    try require(try String(contentsOf: disconnected.appendingPathComponent("history")) == "keep",
      "An unavailable store's contents must remain untouched")
  }

  private static func existingFoldersCanBeAttachedToNewPrefixes(in root: URL) async throws {
    let prefix = root.appendingPathComponent("new-prefix")
    let destination = root.appendingPathComponent("existing-data")
    try write("existing", to: destination.appendingPathComponent("history"))
    try await WineUserData(prefix: prefix).prepare(folder: destination)
    try require(try String(contentsOf: WineUserData.directory(in: prefix).appendingPathComponent("history")) == "existing",
      "A fresh prefix must be able to link an existing folder without replacing its files")
  }

  private static func recursiveLocationsAreRejected(in root: URL) throws {
    let prefix = root.appendingPathComponent("recursive-prefix")
    for location in [prefix, prefix.appendingPathComponent("nested"), root, URL(fileURLWithPath: "/")] {
      do {
        try WineUserData.validate(location, for: prefix)
        throw failure("A destination overlapping the prefix must be rejected: \(location.path)")
      } catch is ApplicationError {}
    }

    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    if let canonical = try prefix.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath,
      canonical.hasPrefix("/private/") {
      let alias = URL(fileURLWithPath: String(canonical.dropFirst("/private".count)))
      do {
        try WineUserData.validate(alias.appendingPathComponent("nested"), for: URL(fileURLWithPath: canonical))
        throw failure("A /var or /tmp alias must not bypass prefix containment")
      } catch is ApplicationError {}
    }
  }

  private static func resetRejectsRecursiveManualLinks(in root: URL) async throws {
    let prefix = root.appendingPathComponent("manual-prefix")
    let path = WineUserData.directory(in: prefix)
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: prefix)
    do {
      try await WineUserData(prefix: prefix).prepare(folder: nil)
      throw failure("Reset must not copy an ancestor into its own subtree")
    } catch is ApplicationError {
      try require((try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil,
        "Rejecting a recursive manual link must leave it untouched")
    }
  }

  private static func write(_ text: String, to path: URL) throws {
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: path, atomically: true, encoding: .utf8)
  }

  private static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw failure(message) }
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "UserDataTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
