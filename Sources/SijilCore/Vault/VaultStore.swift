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
  private let log = Logger(subsystem: "com.buamod.sijil", category: "vault-store")

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

  /// The underlying writer. Exposed so durability tests can publish a file
  /// directly and observe the exact bytes on disk.
  nonisolated public var rawWriter: VaultWriter { writer }

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
    // Every note present on disk, including ones we skipped. A note we did not
    // import still exists, so it must count as "present" for the
    // missing-note check below.
    var presentOnDisk: Set<UUID> = []

    for note in decoded {
      presentOnDisk.insert(note.id)

      // A note from a newer sijil may interpret our fields differently, so it
      // is not imported.
      guard note.schema <= VaultNote.schemaVersion else { continue }

      guard !onDisk.contains(note.id.uuidString) else { continue }
      do {
        // A note for a clip deleted elsewhere must not come back. The vault is
        // never rewritten, so the deletion travels in the sidecar instead.
        if let collections, await collections.isTombstoned(note.id) {
          onDisk.insert(note.id.uuidString)
          continue
        }

        if store.isTombstoned(note.id) {
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
          contents: [
            ClipContent(
              type: PasteboardType.string.rawValue,
              value: Data(note.body.utf8)
            )
          ],
          pinned: note.pinned,
          locked: note.locked,
          // Imported items never carry resurrection rights, so they cannot
          // clear a tombstone.
          isFromLocalCapture: false,
          collection: note.collection,
          useCount: note.useCount,
          title: TextSanitizer.previewLine(note.body)
        )
        // Already marked exported: it came *from* the vault.
        _ = try store.record(item)
        try store.markExported(ids: [item.id])
        onDisk.insert(note.id.uuidString)
        imported += 1
      } catch {
        log.error("import failed for \(note.id.uuidString, privacy: .public)")
      }
    }

    // Anything we hold that no longer has a note on disk gets re-published. The
    // import above only adds what is present, so this is the other direction.
    //
    // A missing note is not a deletion — it means the file went away behind our
    // back (a sync client, a cleanup, an unmounted volume) — so the clip is
    // re-published rather than dropped.
    let missing = (try? missingNoteIDs(present: presentOnDisk)) ?? []
    if !missing.isEmpty {
      try? store.rearmExport(ids: missing)
    }

    // A tombstone whose note is gone has nothing left to block, so it can be
    // collected. Gated on readability: an unreachable vault reports zero notes,
    // and collecting on that basis would resurrect every deleted clip the moment
    // the vault came back.
    _ = try? store.collectTombstonesWithNoNote(
      presentOnDisk: Set(presentOnDisk.map(\.uuidString)),
      isVaultReadable: await writer.isReachable()
    )
    return imported
  }

  /// Ids we hold in SQLite with no note on disk to back them up.
  private func missingNoteIDs(present: Set<UUID>) throws -> [UUID] {
    // Only local captures are re-armed: an imported item has no local
    // obligation to re-publish.
    let known = try store.recent(limit: 100_000, includeUnpinnedOnly: false)
    return
      known
      .filter { $0.isFromLocalCapture && !present.contains($0.id) }
      .map(\.id)
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
