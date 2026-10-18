import Foundation
import Testing

@testable import CopyzCore

/// The end-to-end guarantee behind tombstones: a delete on one machine must
/// survive a vault sync that still carries the note.
@Suite("Deletion propagation")
struct DeletionPropagationTests {
  private func makeStack() throws -> (SQLiteClipStore, VaultStore, CollectionStore, URL) {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "copyz-del-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SQLiteClipStore(inMemory: true)
    let writer = VaultWriter(rootURL: root)
    let sidecar = CollectionStore(sidecarURL: root.appending(path: ".copyz/sidecar.json"))
    let vault = VaultStore(store: store, writer: writer, collections: sidecar)
    return (store, vault, sidecar, root)
  }

  private func cleanup(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
  }

  private func textItem(_ text: String) -> ClipItem {
    ClipItem(contents: [ClipContent(type: PasteboardType.string.rawValue, value: Data(text.utf8))])
  }

  @Test("A deleted clip is not re-imported from the vault")
  func deletedClipStaysDeleted() async throws {
    let (store, vault, sidecar, root) = try makeStack()
    defer { cleanup(root) }
    try await vault.prepare()

    let clip = textItem("delete me, do not bring me back")
    try store.record(clip)
    _ = await vault.flushNow()

    // Delete, tombstoning in both places.
    try store.delete(id: clip.id)
    await sidecar.tombstone(clip.id)
    try await sidecar.save()

    // Re-import: the note is still on disk, so only the tombstone can stop it.
    let imported = await vault.importFromVault()
    #expect(imported == 0)
    #expect(try store.count() == 0)
    #expect(try store.search("delete me", limit: 5).isEmpty)
  }

  @Test("Clearing history propagates every cleared clip")
  func clearHistoryPropagates() async throws {
    let (store, vault, sidecar, root) = try makeStack()
    defer { cleanup(root) }
    try await vault.prepare()

    for index in 0..<4 { try store.record(textItem("item \(index)")) }
    _ = await vault.flushNow()

    let removed = try store.deleteAll(includingPinned: true, tombstone: true)
    #expect(removed.count == 4)
    for id in removed { await sidecar.tombstone(id) }
    try await sidecar.save()

    #expect(await vault.importFromVault() == 0)
    #expect(try store.count() == 0)
  }

  @Test("Locked items survive clearing and stay out of the tombstone set")
  func lockedSurvivesClear() async throws {
    let (store, vault, sidecar, root) = try makeStack()
    defer { cleanup(root) }
    try await vault.prepare()

    let locked = textItem("must survive")
    try store.record(locked)
    try store.setLocked(true, id: locked.id)
    try store.record(textItem("ordinary"))

    let removed = try store.deleteAll(includingPinned: true, tombstone: true)
    #expect(removed.count == 1)
    #expect(store.isTombstoned(locked.id) == false)

    // Re-import must not duplicate the locked clip either.
    _ = await vault.importFromVault()
    #expect(try store.count() == 1)
    #expect(try store.recent(limit: 5, includeUnpinnedOnly: false).first?.locked == true)
  }

  @Test("Purging the index does not create tombstones")
  func purgeDoesNotTombstone() async throws {
    let (store, vault, _, root) = try makeStack()
    defer { cleanup(root) }
    try await vault.prepare()

    try store.record(textItem("recoverable"))
    _ = await vault.flushNow()

    // A lost database is not a user delete, so recovery must still work.
    _ = try store.deleteAll(includingPinned: true, tombstone: false)
    #expect(try store.tombstoneCount() == 0)
    #expect(await vault.importFromVault() == 1)
    #expect(try store.count() == 1)
  }

  @Test("Tombstones survive a sidecar round trip")
  func tombstonesPersist() async throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "copyz-ts-\(UUID().uuidString).json")
    defer { cleanup(url) }
    let clipID = UUID()

    do {
      let first = CollectionStore(sidecarURL: url)
      await first.tombstone(clipID)
      try await first.save()
    }

    let second = CollectionStore(sidecarURL: url)
    #expect(await second.isTombstoned(clipID))
  }

  @Test("An older tombstone cannot overwrite a newer pin")
  func tombstoneAndPinUseTheSameClock() async throws {
    let (_, _, sidecar, root) = try makeStack()
    defer { cleanup(root) }

    let clipID = UUID()
    await sidecar.setPinned(true, clipID: clipID)
    await sidecar.tombstone(clipID, at: Date(timeIntervalSinceNow: -600))

    // The pin is newer, so the tombstone must not apply.
    let merged = await sidecar.pinRecord(for: clipID)
    #expect(merged?.pinned == true)
  }

  @Test("Tombstones are prunable so the sidecar cannot grow forever")
  func tombstonesPrunable() async {
    let sidecar = CollectionStore(sidecarURL: nil)
    let old = UUID()
    let recent = UUID()

    await sidecar.tombstone(old, at: Date(timeIntervalSince1970: 1_000))
    await sidecar.tombstone(recent, at: Date())
    await sidecar.pruneTombstones(olderThan: Date(timeIntervalSince1970: 500_000))

    #expect(await sidecar.isTombstoned(old) == false)
    #expect(await sidecar.isTombstoned(recent))
  }

  @Test("Lock state round-trips through a vault note")
  func lockRoundTripsThroughNote() throws {
    let locked = ClipItem(
      contents: [ClipContent(type: PasteboardType.string.rawValue, value: Data("x".utf8))],
      locked: true
    )
    let decoded = try #require(VaultNote.decode(VaultNote.encode(locked)))
    #expect(decoded.locked)
    #expect(VaultNote.encode(locked).contains("locked: true"))
  }
}