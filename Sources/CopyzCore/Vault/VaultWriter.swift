import Foundation
import os

/// Writes clips into the vault folder as Markdown notes plus binary assets.
///
/// This is the entire "sync" layer. Point `rootURL` at a Dropbox, Google Drive,
/// iCloud Drive, or Obsidian vault folder and the sync client the user already
/// runs does the rest — no OAuth, no tokens, no rate limits, no conflict
/// resolution.
///
/// Import is deliberately **read-only**. The vault is never modified or deleted
/// from during a scan; pruning happens in SQLite. That way a bug here can lose
/// nothing the user cares about.
public actor VaultWriter {
  private let rootURL: URL
  private let fileManager: FileManager
  private let log = Logger(subsystem: "app.copyz", category: "vault")

  /// Ids known to be on disk, so export skips them.
  private var writtenIDs: Set<String> = []

  public enum Failure: LocalizedError {
    case rootMissing(URL)
    case writeFailed(URL, underlying: Error)

    public var errorDescription: String? {
      switch self {
      case .rootMissing(let url):
        "The vault folder is not available: \(url.path)"
      case .writeFailed(let url, let underlying):
        "Could not write \(url.lastPathComponent): \(underlying.localizedDescription)"
      }
    }
  }

  public init(rootURL: URL, fileManager: FileManager = .default) {
    self.rootURL = rootURL
    self.fileManager = fileManager
  }

  public var url: URL { rootURL }

  /// Creates the directory skeleton, including the vault root itself. Cheap and
  /// idempotent, so it is safe on every launch.
  ///
  /// Creating the root here matters: the caller may point the vault at a folder
  /// that does not exist yet on first run, and a bare existence check would
  /// then fail forever.
  public func prepare() throws {
    do {
      try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    } catch {
      throw Failure.rootMissing(rootURL)
    }

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else {
      throw Failure.rootMissing(rootURL)
    }

    try fileManager.createDirectory(
      at: rootURL.appending(path: "Clips", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
      at: rootURL.appending(path: "assets", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
  }

  /// True when the vault folder is still reachable. Checked before each export
  /// burst so a moved or unmounted folder surfaces as a warning rather than
  /// silent data loss.
  public func isReachable() -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  /// Writes one clip. Returns the note's relative path.
  @discardableResult
  public func write(_ item: ClipItem) throws -> String {
    guard isReachable() else { throw Failure.rootMissing(rootURL) }

    let relative = VaultNote.relativePath(for: item)
    let noteURL = rootURL.appending(path: relative)

    // Binary payload first: a note referencing a missing asset is worse than a
    // late note.
    if let assetName = VaultNote.assetName(for: item),
       let data = VaultNote.assetData(for: item) {
      let assetURL = rootURL.appending(path: "assets/\(assetName)")
      if !fileManager.fileExists(atPath: assetURL.path) {
        do {
          try data.write(to: assetURL, options: [.atomic])
        } catch {
          log.error("asset write failed: \(error.localizedDescription, privacy: .public)")
          throw Failure.writeFailed(assetURL, underlying: error)
        }
      }
    }

    try fileManager.createDirectory(
      at: noteURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let note = VaultNote.encode(item)
    do {
      // Atomic so a sync client never observes a half-written note.
      try Data(note.utf8).write(to: noteURL, options: [.atomic])
    } catch {
      log.error("note write failed: \(error.localizedDescription, privacy: .public)")
      throw Failure.writeFailed(noteURL, underlying: error)
    }

    writtenIDs.insert(item.id.uuidString)
    return relative
  }

  /// Writes a batch, returning the ids that succeeded. Failures are logged and
  /// skipped so one unwritable item cannot stall the queue.
  @discardableResult
  public func writeBatch(_ items: [ClipItem]) -> [UUID] {
    var written: [UUID] = []
    for item in items {
      do {
        try write(item)
        written.append(item.id)
      } catch {
        log.error("skipping \(item.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
      }
    }
    return written
  }

  // MARK: - Import

  /// Everything the vault currently holds, newest first.
  ///
  /// Walks only the `Clips/` subtree and skips `.copyz/`. Errors on individual
  /// unreadable files are tolerated — a half-synced vault still yields
  /// whatever is readable.
  public func readAll(limit: Int = .max) -> [VaultNote.Decoded] {
    guard isReachable() else { return [] }
    let clipsRoot = rootURL.appending(path: "Clips", directoryHint: .isDirectory)
    guard
      let enumerator = fileManager.enumerator(
        at: clipsRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    var results: [VaultNote.Decoded] = []
    for case let fileURL as URL in enumerator {
      guard fileURL.pathExtension == "md" else { continue }
      guard let data = try? Data(contentsOf: fileURL),
            let text = String(data: data, encoding: .utf8),
            let decoded = VaultNote.decode(text)
      else { continue }
      results.append(decoded)
      if results.count >= limit { break }
    }
    return results.sorted { $0.createdAt > $1.createdAt }
  }

  /// Approximate on-disk size, for the settings pane.
  public func byteSize() -> Int64 {
    guard
      let enumerator = fileManager.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return 0 }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard values?.isRegularFile == true else { continue }
      total += Int64(values?.fileSize ?? 0)
    }
    return total
  }

  /// Replaces the vault's contents with `items`, for "Move vault" style
  /// operations. Existing files that are not in `items` are removed, which is
  /// why this is explicit rather than part of normal export.
  public func mirror(_ items: [ClipItem]) throws {
    try prepare()
    let keep = Set(items.map(\.id.uuidString))
    let existing = readAll()

    for clip in existing where !keep.contains(clip.id.uuidString) {
      let relative = VaultNote.relativePath(
        createdAt: clip.createdAt,
        contentHash: clip.contentHash
      )
      try? fileManager.removeItem(at: rootURL.appending(path: relative))
    }

    _ = writeBatch(items)
  }
}