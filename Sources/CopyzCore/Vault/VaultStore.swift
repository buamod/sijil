import Foundation
import os

/// Bridges SQLite and the vault.
///
/// The two stores are deliberately **not** master and slave. SQLite is the
/// queryable index and receives every capture immediately; the vault is the
/// durable, synced record and receives them on a debounce. Neither can lose the
/// user's history alone:
///
/// - Crash before export → the launch reconcile flushes SQLite rows the vault
///   never received.
/// - SQLite deleted → "Rebuild from vault" reconstructs everything from the
///   Markdown notes.
public actor VaultStore {
  private let store: SQLiteClipStore
  private let writer: VaultWriter
  /// Collection and tombstone metadata. Held here so import can consult it.
  public let collections: CollectionStore?
  private let log = Logger(subsystem: "app.copyz", category: "vault-store")

  /// Ids known to be present on disk, so export skips them without a disk read.
  private var onDisk: Set<String> = []

  /// Flush at most this often. Long enough that a burst of copying coalesces,
  /// short enough that a crash loses very little.
  private let debounce: Duration
  private var flushTask: Task<Void, Never>?

  /// Cap per flush so one huge backlog cannot monopolise the actor.
  private let batchSize = 200

  public init(
    store: SQLiteClipStore,
    writer: VaultWriter,
    collections: CollectionStore? = nil,
    debounce: Duration = .seconds(30)
  ) {
    self.store = store
    self.writer = writer
    self.collections = collections
    self.debounce = debounce
  }

  public func prepare() async throws {
    try await writer.prepare()
  }

  public func vaultURL() async -> URL {
    await writer.url
  }

  // MARK: - Export

  /// Queues a flush after the debounce window.
  public func scheduleFlush() {
    flushTask?.cancel()
    flushTask = Task { [debounce] in
      try? await Task.sleep(for: debounce)
      guard !Task.isCancelled else { return }
      await self.flushNow()
    }
  }

  /// Writes everything not yet on disk. Returns how many notes were written.
  @discardableResult
  public func flushNow() async -> Int {
    guard await writer.isReachable() else {
      log.error("vault unreachable; skipping flush")
      return 0
    }

    var written = 0
    while true {
      let pending: [ClipItem]
      do {
        pending = try store.pendingExport(limit: batchSize)
      } catch {
        log.error("pendingExport failed: \(error.localizedDescription, privacy: .public)")
        return written
      }
      guard !pending.isEmpty else { break }

      let succeeded = await writer.writeBatch(pending)
      guard !succeeded.isEmpty else {
        // Nothing succeeded; retrying immediately would spin.
        log.error("vault write batch made no progress; stopping flush")
        return written
      }

      do {
        try store.markExported(ids: succeeded)
      } catch {
        log.error("markExported failed: \(error.localizedDescription, privacy: .public)")
      }
      written += succeeded.count
      if pending.count < batchSize { break }
    }
    return written
  }

  // MARK: - Import

  /// Pulls any vault notes SQLite has not seen and records them.
  ///
  /// Read-only by design: notes are never rewritten and files are never deleted
  /// from the vault by an import, so a bug here cannot destroy anything.
  @discardableResult
  public func importFromVault() async -> Int {
    let decoded = await writer.readAll(limit: 20_000)
    var imported = 0

    for note in decoded {
      guard !onDisk.contains(note.id.uuidString) else { continue }
      do {
        // A note for a clip deleted elsewhere must not come back. The vault is
        // never rewritten, so the deletion travels in the sidecar instead.
        if let collections, await collections.isTombstoned(note.id) {
          onDisk.insert(note.id.uuidString)
          continue
        }

        if try store.isTombstoned(note.id) {
          onDisk.insert(note.id.uuidString)
          continue
        }

        if try store.item(matchingContentHash: note.contentHash) != nil {
          onDisk.insert(note.id.uuidString)
          continue
        }

        let item = ClipItem(
          id: note.id,
          createdAt: note.createdAt,
          lastUsedAt: note.createdAt,
          sourceBundleID: note.sourceBundleID,
          sourceAppName: note.sourceAppName,
          contents: [ClipContent(
            type: PasteboardType.string.rawValue,
            value: Data(note.body.utf8)
          )],
          pinned: note.pinned,
          locked: note.locked,
          collection: note.collection,
          useCount: note.useCount,
          title: TextSanitizer.previewLine(note.body)
        )
        // Already marked exported: it came *from* the vault.
        _ = try store.record(item)
        try store.markExported(ids: [item.id])
        onDisk.insert(item.id.uuidString)
        imported += 1
      } catch {
        log.error("import failed for \(note.id.uuidString, privacy: .public)")
      }
    }
    return imported
  }

  /// Rebuilds the index from the vault. Safe to run at any time; the caller is
  /// expected to hold a fresh or emptied store.
  public func rebuildIndex() async throws -> Int {
    onDisk.removeAll()
    return await importFromVault()
  }

  /// Writes one item immediately, bypassing the debounce. Used for metadata
  /// changes — a pin toggle should show up in the vault without waiting.
  public func writeNow(_ item: ClipItem) async {
    guard await writer.isReachable() else { return }
    let written = await writer.writeBatch([item])
    if !written.isEmpty {
      try? store.markExported(ids: written)
    }
  }

  // MARK: - Stats

  public func byteSize() async -> Int64 {
    await writer.byteSize()
  }

  /// Reads back what the vault currently holds.
  public func readAll(limit: Int = 20_000) async -> [VaultNote.Decoded] {
    await writer.readAll(limit: limit)
  }

  /// Flushes on shutdown so nothing pending is lost on quit.
  public func flushOnShutdown() async {
    flushTask?.cancel()
    _ = await flushNow()
  }
}