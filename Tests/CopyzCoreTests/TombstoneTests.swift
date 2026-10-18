import Foundation
import Testing

@testable import CopyzCore

/// Tombstones and the locked state.
///
/// Both were found missing by comparing against PastePal's live schema, which
/// carries `ZMARKEDDELETE` and `ZLOCKED` columns that we had no equivalent for.
/// A tombstone matters because vault import is read-only: without one, a clip
/// deleted on one machine is faithfully re-imported from the note another
/// machine still has, so the delete silently un-does itself.
@Suite("Tombstones")
struct TombstoneTests {
  private func makeStore() throws -> SQLiteClipStore {
    try SQLiteClipStore(inMemory: true)
  }

  private func item(_ text: String, at offset: TimeInterval = 1_000) -> ClipItem {
    ClipItem(
      createdAt: Date(timeIntervalSince1970: offset),
      contents: [ClipContent(type: PasteboardType.string.rawValue, value: Data(text.utf8))]
    )
  }

  @Test("A tombstoned clip is not resurrected by re-import")
  func tombstoneBlocksReimport() throws {
    let store = try makeStore()
    let clip = item("delete me")
    try store.record(clip)

    try store.tombstone(clip.id)

    // Simulate the other machine still having the note: the vault importer
    // preserves the note's original id, so re-recording that id must be a no-op.
    // A vault import carries no resurrection rights.
    let reimported = ClipItem(
      id: clip.id,
      createdAt: clip.createdAt,
      contents: [ClipContent(
        type: PasteboardType.string.rawValue,
        value: Data("delete me".utf8)
      )],
      isFromLocalCapture: false
    )
    _ = try store.record(reimported)

    #expect(try store.count() == 0, "tombstoned clip must not be re-imported")
  }

  @Test("Tombstones survive a store reopen")
  func tombstonesPersist() throws {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "copyz-tomb-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appending(path: "history.sqlite").path

    let clipID: UUID
    do {
      let store = try SQLiteClipStore(path: path)
      let clip = item("gone for good")
      try store.record(clip)
      try store.tombstone(clip.id)
      clipID = clip.id
    }

    let reopened = try SQLiteClipStore(path: path)
    #expect(reopened.isTombstoned(clipID))
  }

  @Test("Locked items survive a full purge")
  func lockedSurvivesPurge() throws {
    let store = try makeStore()
    let locked = item("locked item")
    try store.record(locked)
    try store.setLocked(true, id: locked.id)
    try store.record(item("ordinary item", at: 1_001))

    try store.deleteAll(includingPinned: true)

    let remaining = try store.recent(limit: 10, includeUnpinnedOnly: false)
    #expect(remaining.count == 1)
    #expect(remaining.first?.id == locked.id)
    #expect(remaining.first?.locked == true)
  }

  @Test("Locked items survive retention pruning")
  func lockedSurvivesPrune() throws {
    let store = try makeStore()
    let old = Date(timeIntervalSince1970: 1_000)
    let locked = ClipItem(
      createdAt: old,
      contents: [ClipContent(type: PasteboardType.string.rawValue, value: Data("keep".utf8))],
      locked: true
    )
    try store.record(locked)
    try store.record(item("expire", at: old.timeIntervalSince1970))

    let removed = try store.prune(
      policy: RetentionPolicy(
        fullFidelityWindow: 10,
        textTailWindow: 10,
        maximumItems: nil
      ),
      now: Date(timeIntervalSince1970: 1_000_000)
    )

    #expect(removed.count == 1)
    #expect(try store.count() == 1)
    #expect(try store.recent(limit: 10, includeUnpinnedOnly: false).first?.locked == true)
  }

  @Test("Locked state is exempt from the item ceiling")
  func lockedExemptFromCeiling() throws {
    let store = try makeStore()
    let locked = item("ancient but locked", at: 100)
    try store.record(locked)
    try store.setLocked(true, id: locked.id)
    for index in 0..<5 {
      try store.record(item("item \(index)", at: TimeInterval(1_000 + index)))
    }

    _ = try store.prune(
      policy: RetentionPolicy(
        fullFidelityWindow: .greatestFiniteMagnitude,
        textTailWindow: nil,
        maximumItems: 2
      ),
      now: Date(timeIntervalSince1970: 5_000)
    )

    let remaining = try store.recent(limit: 10, includeUnpinnedOnly: false)
    #expect(remaining.count == 2)
    #expect(remaining.contains { $0.id == locked.id })
  }

  @Test("Clearing history writes tombstones so the delete can propagate")
  func clearWritesTombstones() throws {
    let store = try makeStore()
    let first = item("one")
    let second = item("two")
    try store.record(first)
    try store.record(second)

    let cleared = try store.deleteAll(includingPinned: true)
    #expect(cleared.count == 2)
    #expect(try store.count() == 0)
    // Every cleared clip is now tombstoned.
    #expect(try store.tombstoneCount() == 2)
    #expect(store.isTombstoned(first.id))
    #expect(store.isTombstoned(second.id))
  }

  @Test("Tombstones are themselves retained, then pruned by age")
  func tombstonesArePruned() throws {
    let store = try makeStore()
    let old = ClipItem(
      createdAt: Date(timeIntervalSince1970: 1_000),
      contents: [ClipContent(type: PasteboardType.string.rawValue, value: Data("ancient".utf8))]
    )
    try store.record(old)
    try store.tombstone(old.id, at: Date(timeIntervalSince1970: 1_000))

    let pruned = try store.pruneTombstones(olderThan: Date(timeIntervalSince1970: 500_000))
    #expect(pruned == 1)
    #expect(store.isTombstoned(old.id) == false)
  }

  @Test("Unlocking returns an item to normal retention")
  func unlockRestoresNormalRetention() throws {
    let store = try makeStore()
    let locked = item("temp locked", at: 1_000)
    try store.record(locked)
    try store.setLocked(true, id: locked.id)
    try store.setLocked(false, id: locked.id)

    _ = try store.prune(
      policy: RetentionPolicy(
        fullFidelityWindow: 10,
        textTailWindow: 10,
        maximumItems: nil
      ),
      now: Date(timeIntervalSince1970: 1_000_000)
    )
    #expect(try store.count() == 0)
  }
}