import Foundation
import Testing

@testable import CopyzCore

/// Maintenance must reclaim space without ever losing the ability to honour a
/// deletion. Both halves matter: a store that never shrinks will eventually fill
/// the disk, and a store that collects a tombstone too eagerly resurrects data
/// the user asked to forget.
@Suite("Store maintenance")
struct MaintenanceTests {
  private func temporaryStore() throws -> (SQLiteClipStore, URL) {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "copyz-maint-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (try SQLiteClipStore(path: dir.appending(path: "h.sqlite").path), dir)
  }

  private func textItem(_ text: String) -> ClipItem {
    ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data(text.utf8))
    ])
  }

  /// Total on-disk footprint. WAL writes are buffered, so the main file alone
  /// badly understates how much space a store is actually using.
  private func fileSize(ofStoreAt dir: URL) -> Int64 {
    let base = dir.appending(path: "h.sqlite").path
    return [base, base + "-wal", base + "-shm"]
      .reduce(into: Int64(0)) { total, path in
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
      }
  }

  // MARK: - Compaction

  @Test("A fresh store has nothing worth compacting")
  func freshStoreIsSkipped() throws {
    let (store, dir) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    for index in 0..<50 { _ = try store.record(textItem("clip \(index)")) }
    // Nothing has been deleted, so there is no free space to reclaim.
    #expect(try store.compactIfNeeded() == 0)
  }

  @Test("A forced compact runs and leaves the store readable")
  func forcedCompactKeepsData() throws {
    let (store, dir) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let dbURL = dir.appending(path: "h.sqlite")

    for index in 0..<200 { _ = try store.record(textItem("durable content \(index)")) }
    let before = try store.count()

    try store.compact(force: true)

    #expect(try store.count() == before, "compaction must not lose rows")
    #expect(try store.search("durable", limit: 10).isEmpty == false)
    // Writes still work afterwards, which proves the pool survived VACUUM.
    _ = try store.record(textItem("after compaction"))
    #expect(try store.count() == before + 1)
    #expect(fileSize(ofStoreAt: dir) > 0)
  }

  @Test("Deleting most of the store makes compaction worthwhile")
  func deletionMakesCompactionWorthwhile() throws {
    let (store, dir) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    var ids: [UUID] = []
    for index in 0..<400 {
      ids.append(try store.record(textItem(String(repeating: "y", count: 400) + " \(index)")).id)
    }

    // Force a full checkpoint first, so `fullSize` reflects everything written
    // rather than whatever the WAL is still holding.
    try store.compact(force: true)
    let fullSize = fileSize(ofStoreAt: dir)

    for id in ids.dropLast(10) { try store.delete(id: id) }
    #expect(try store.count() == 10)

    let reclaimed = try store.compactIfNeeded(minimumReclaimableFraction: 0.1)
    #expect(reclaimed > 0, "expected reclaimable pages after deleting 390 rows")
    try store.compact(force: true)
    #expect(fileSize(ofStoreAt: dir) < fullSize, "compaction must return pages to the filesystem")
    #expect(try store.count() == 10)
  }

  @Test("Search still works after compaction")
  func searchSurvivesCompaction() throws {
    let (store, dir) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    for index in 0..<100 { _ = try store.record(textItem("findable-\(index)")) }
    for index in 0..<90 {
      try store.delete(id: try #require(store.search("findable", limit: 100).last).id)
    }

    try store.compact(force: true)

    let hits = try store.search("findable", limit: 20)
    #expect(hits.count == 10)
    #expect(hits.allSatisfy { $0.contentHash.isEmpty == false })
  }

  // MARK: - Tombstone collection

  @Test("A tombstone with no note on disk can be collected")
  func collectsTombstoneWithNoNote() throws {
    let (store, dir) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let deleted = try store.record(textItem("delete me")).id
    try store.tombstone(deleted)
    #expect(try store.tombstoneCount() == 1)

    let collected = try store.collectTombstonesWithNoNote(
      presentOnDisk: [],
      isVaultReadable: true
    )
    #expect(collected == 1)
    #expect(try store.tombstoneCount() == 0)
  }

  @Test("A tombstone whose note is still in the vault is kept")
  func keepsTombstoneWithNote() throws {
    let (store, dir) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let deleted = try store.record(textItem("delete me")).id
    try store.tombstone(deleted)

    // The note survives because copyz never rewrites the vault, so the tombstone
    // is the only thing preventing a re-import.
    let collected = try store.collectTombstonesWithNoNote(
      presentOnDisk: [deleted.uuidString],
      isVaultReadable: true
    )
    #expect(collected == 0)
    #expect(try store.tombstoneCount() == 1)
    #expect(store.isTombstoned(deleted))
  }

  @Test("An unreadable vault collects nothing")
  func unreadableVaultCollectsNothing() throws {
    let (store, dir) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let deleted = try store.record(textItem("delete me")).id
    try store.tombstone(deleted)

    // The bug this guards: an unreachable vault reports zero notes, and
    // collecting on that basis would erase every tombstone. The vault coming
    // back would then resurrect everything the user deleted.
    let collected = try store.collectTombstonesWithNoNote(
      presentOnDisk: [],
      isVaultReadable: false
    )
    #expect(collected == 0)
    #expect(try store.tombstoneCount() == 1, "deletions must survive an offline vault")
  }

  @Test("Collection is selective across a mixed set")
  func selectiveCollection() throws {
    let (store, dir) = try temporaryStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let withNote = try store.record(textItem("still on disk")).id
    let withoutNote = try store.record(textItem("note removed by hand")).id
    try store.tombstone(withNote)
    try store.tombstone(withoutNote)

    let collected = try store.collectTombstonesWithNoNote(
      presentOnDisk: [withNote.uuidString],
      isVaultReadable: true
    )
    #expect(collected == 1)
    #expect(store.isTombstoned(withNote))
    #expect(store.isTombstoned(withoutNote) == false)
  }
}

/// End-to-end: the vault must never resurrect a deleted clip, including across a
/// period where the vault was unreachable.
@Suite("Deletion durability")
struct DeletionDurabilityTests {
  private func makeVault() throws -> (SQLiteClipStore, VaultStore, URL) {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "copyz-del-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SQLiteClipStore(inMemory: true)
    return (store, VaultStore(store: store, writer: VaultWriter(rootURL: root)), root)
  }

  @Test("An offline vault does not resurrect a deleted clip on return")
  func offlineVaultDoesNotResurrect() async throws {
    let (store, vault, root) = try makeVault()
    defer { try? FileManager.default.removeItem(at: root) }
    try await vault.prepare()

    let clip = ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data("secret meeting notes".utf8))
    ])
    _ = try store.record(clip)
    _ = await vault.flushNow()

    try store.tombstone(clip.id)
    #expect(try store.count() == 0)

    // The vault goes away, exactly as an unmounted iCloud Drive would.
    let away = root.deletingLastPathComponent()
      .appending(path: root.lastPathComponent + ".gone")
    try FileManager.default.moveItem(at: root, to: away)

    // Several maintenance rounds happen while it is missing. Each sees zero
    // notes and must conclude nothing about what was deleted.
    for _ in 0..<3 {
      _ = await vault.importFromVault()
      #expect(try store.tombstoneCount() == 1, "tombstone must survive an offline vault")
    }

    // It comes back. The note is still there, and the deletion still wins.
    try FileManager.default.moveItem(at: away, to: root)
    let imported = await vault.importFromVault()

    #expect(imported == 0, "the deleted clip must not come back")
    #expect(try store.count() == 0)
    #expect(try store.search("secret", limit: 5).isEmpty)
  }

  @Test("A deleted clip stays deleted across a full index rebuild")
  func survivesIndexRebuild() async throws {
    let (store, vault, root) = try makeVault()
    defer { try? FileManager.default.removeItem(at: root) }
    try await vault.prepare()

    let keep = ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data("keep this".utf8))
    ])
    let drop = ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data("delete this".utf8))
    ])
    _ = try store.record(keep)
    _ = try store.record(drop)
    _ = await vault.flushNow()

    try store.tombstone(drop.id)
    _ = try await vault.rebuildIndex()

    let titles = try store.recent(limit: 20, includeUnpinnedOnly: false).map(\.contentHash)
    #expect(titles.count == 1)
    #expect(try store.search("delete this", limit: 5).isEmpty)
    #expect(try store.search("keep this", limit: 5).count == 1)
  }
}
