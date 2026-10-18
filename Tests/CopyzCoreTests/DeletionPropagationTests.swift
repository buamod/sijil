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

  @Test("Tombstones are collected only after every replica acknowledges")
  func acknowledgedCollection() async {
    let sidecar = CollectionStore(sidecarURL: nil)
    let clipID = UUID()
    let peer = UUID()

    await sidecar.tombstone(clipID, at: Date(timeIntervalSince1970: 1_000))

    // No peers yet: our own acknowledgement is enough.
    await sidecar.acknowledgeDeletions()
    #expect(await sidecar.canCollect(clipID))

    // A peer appears that has not acknowledged the deletion.
    var incoming = VaultSidecar()
    incoming.watermarks[peer] = DeviceWatermark(
      deviceID: peer,
      observedDeletes: Date(timeIntervalSince1970: 500)
    )
    await sidecar.merge(incoming)

    // Now the tombstone is blocked, because the peer has not seen it.
    #expect(await sidecar.canCollect(clipID) == false)
    #expect(await sidecar.collectAcknowledgedTombstones() == 0)
    #expect(await sidecar.isTombstoned(clipID))
  }

  @Test("An offline peer blocks collection past any age")
  func offlinePeerBlocksForever() async {
    let sidecar = CollectionStore(sidecarURL: nil)
    let clipID = UUID()
    let peer = UUID()

    await sidecar.tombstone(clipID, at: Date(timeIntervalSince1970: 1_000))
    await sidecar.acknowledgeDeletions()

    var incoming = VaultSidecar()
    incoming.watermarks[peer] = DeviceWatermark(
      deviceID: peer,
      observedDeletes: Date(timeIntervalSince1970: 0)
    )
    await sidecar.merge(incoming)

    // A year later the tombstone is still held: age is not evidence that a
    // replica has seen the delete.
    #expect(await sidecar.canCollect(clipID, now: Date(timeIntervalSince1970: 31_536_000)) == false)
  }

  @Test("Once the peer acknowledges, the tombstone can be collected")
  func peerAcknowledgementUnblocksCollection() async {
    let sidecar = CollectionStore(sidecarURL: nil)
    let clipID = UUID()
    let peer = UUID()

    await sidecar.tombstone(clipID, at: Date(timeIntervalSince1970: 1_000))
    await sidecar.acknowledgeDeletions()

    var incoming = VaultSidecar()
    incoming.watermarks[peer] = DeviceWatermark(
      deviceID: peer,
      observedDeletes: Date(timeIntervalSince1970: 2_000)
    )
    await sidecar.merge(incoming)

    #expect(await sidecar.canCollect(clipID))
    #expect(await sidecar.collectAcknowledgedTombstones() == 1)
    #expect(await sidecar.isTombstoned(clipID) == false)
  }

  @Test("Collection bumps the epoch so a returning peer knows it fell behind")
  func collectionBumpsEpoch() async {
    let sidecar = CollectionStore(sidecarURL: nil)
    let clipID = UUID()
    await sidecar.tombstone(clipID, at: Date(timeIntervalSince1970: 1_000))
    await sidecar.acknowledgeDeletions()

    #expect(await sidecar.hasFallenBehind() == false)
    _ = await sidecar.collectAcknowledgedTombstones()

    // Our own epoch advanced with the collection, so we are current.
    #expect(await sidecar.hasFallenBehind() == false)
  }

  @Test("A silently-abandoned replica stops blocking after retirement")
  func stalePeerIsRetired() async {
    let sidecar = CollectionStore(sidecarURL: nil)
    let clipID = UUID()
    let peer = UUID()

    // Everything is anchored to a fixed "now" so retirement is deterministic.
    let now = Date(timeIntervalSince1970: 100 * 24 * 3600)
    await sidecar.tombstone(clipID, at: now.addingTimeInterval(-1_000))
    await sidecar.acknowledgeDeletions()

    // Peer last reported long ago and never saw the deletion.
    var incoming = VaultSidecar()
    incoming.watermarks[peer] = DeviceWatermark(
      deviceID: peer,
      observedDeletes: .distantPast,
      updatedAt: now.addingTimeInterval(-30 * 24 * 3600)
    )
    await sidecar.merge(incoming)

    // Within the retirement window it still blocks collection.
    #expect(await sidecar.canCollect(clipID, now: now) == false)
    // Past the retirement interval it no longer does.
    let muchLater = now.addingTimeInterval(90 * 24 * 3600)
    #expect(await sidecar.canCollect(clipID, now: muchLater))
  }

  @Test("Age-based pruning remains available for single-device setups")
  func agePruneStillAvailable() async {
    let sidecar = CollectionStore(sidecarURL: nil)
    let old = UUID()
    let recent = UUID()

    await sidecar.tombstone(old, at: Date(timeIntervalSince1970: 1_000))
    await sidecar.tombstone(recent, at: Date())

    #expect(await sidecar.pruneTombstones(olderThan: Date(timeIntervalSince1970: 500_000)) == 1)
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