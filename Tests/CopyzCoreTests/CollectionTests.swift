import Foundation
import Testing

@testable import CopyzCore

@Suite("CollectionStore")
struct CollectionStoreTests {
  private func makeStore() -> (CollectionStore, URL) {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "copyz-sidecar-\(UUID().uuidString).json")
    return (CollectionStore(sidecarURL: url), url)
  }

  private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  @Test("Adding and listing collections")
  func addAndList() async {
    let (store, url) = makeStore()
    defer { cleanup(url) }

    await store.upsert(Collection(name: "Work"))
    await store.upsert(Collection(name: "Personal"))
    let collections = await store.collections
    #expect(collections.map(\.name) == ["Work", "Personal"])
  }

  @Test("Renaming by name updates in place rather than duplicating")
  func upsertMergesByName() async {
    let (store, url) = makeStore()
    defer { cleanup(url) }

    let created = await store.upsert(Collection(name: "Work"))
    let updated = await store.upsert(Collection(name: "work"))
    #expect(updated.id == created.id)
    #expect(await store.collections.count == 1)
  }

  @Test("Rename changes the name and keeps the identity")
  func rename() async {
    let (store, url) = makeStore()
    defer { cleanup(url) }

    let collection = await store.upsert(Collection(name: "Old"))
    let renamed = await store.rename(collection.id, to: "New")
    #expect(renamed?.name == "New")
    #expect(renamed?.id == collection.id)
  }

  @Test("Blank renames are refused")
  func blankRenameRefused() async {
    let (store, url) = makeStore()
    defer { cleanup(url) }

    let collection = await store.upsert(Collection(name: "Keep"))
    #expect(await store.rename(collection.id, to: "   ") == nil)
    #expect(await store.collection(id: collection.id)?.name == "Keep")
  }

  @Test("Deleting a collection un-files its items but keeps them")
  func deleteUnfiles() async {
    let (store, url) = makeStore()
    defer { cleanup(url) }

    let collection = await store.upsert(Collection(name: "Temp"))
    let clipID = UUID()
    await store.setCollection(collection.id, clipID: clipID)

    await store.deleteCollection(collection.id)
    #expect(await store.collections.isEmpty)
    // The clip survives, just unfiled.
    #expect(await store.collectionID(for: clipID) == nil)
  }

  @Test("Pin toggling")
  func pinToggling() async {
    let (store, url) = makeStore()
    defer { cleanup(url) }

    let clipID = UUID()
    #expect(await store.isPinned(clipID) == false)
    #expect(await store.togglePinned(clipID) == true)
    #expect(await store.isPinned(clipID))
    #expect(await store.togglePinned(clipID) == false)
  }

  @Test("Protected clips include pinned and filed items")
  func protectedClips() async {
    let (store, url) = makeStore()
    defer { cleanup(url) }

    let collection = await store.upsert(Collection(name: "Keepers"))
    let pinned = UUID()
    let filed = UUID()
    let loose = UUID()

    await store.setPinned(true, clipID: pinned)
    await store.setCollection(collection.id, clipID: filed)

    let protectedIDs = await store.protectedClipIDs()
    #expect(protectedIDs.contains(pinned))
    #expect(protectedIDs.contains(filed))
    #expect(protectedIDs.contains(loose) == false)
  }

  @Test("Sidecar round-trips through disk")
  func persists() async throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "copyz-sidecar-\(UUID().uuidString).json")
    defer { cleanup(url) }

    let clipID = UUID()
    let collectionID = UUID()

    do {
      let first = CollectionStore(sidecarURL: url)
      let collection = await first.upsert(
        Collection(id: collectionID, name: "Persisted")
      )
      await first.setPinned(true, clipID: clipID)
      await first.setCollection(collection.id, clipID: clipID)
      try await first.save()
      #expect(await first.collections.count == 1)
    }

    #expect(FileManager.default.fileExists(atPath: url.path))

    let second = CollectionStore(sidecarURL: url)
    #expect(await second.collections.map(\.name) == ["Persisted"])
    #expect(await second.isPinned(clipID))
    #expect(await second.collectionID(for: clipID) == collectionID)
  }

  @Test("An older record cannot overwrite a newer one")
  func lastWriterWins() async {
    let (store, url) = makeStore()
    defer { cleanup(url) }

    let clipID = UUID()
    // Newer pin state.
    await store.setPinned(true, clipID: clipID)

    // An older sync arriving from another machine must not undo it.
    var incoming = VaultSidecar()
    incoming.pins[clipID] = PinRecord(
      clipID: clipID,
      pinned: false,
      updatedAt: Date(timeIntervalSinceNow: -600)
    )
    await store.merge(incoming)

    #expect(await store.isPinned(clipID) == true)
  }

  @Test("A newer record does overwrite")
  func newerRecordWins() async {
    let (store, url) = makeStore()
    defer { cleanup(url) }

    let clipID = UUID()
    await store.setPinned(false, clipID: clipID)

    var incoming = VaultSidecar()
    incoming.pins[clipID] = PinRecord(clipID: clipID, pinned: true, updatedAt: Date())
    await store.merge(incoming)

    #expect(await store.isPinned(clipID) == true)
  }

  @Test("Collection slugs are filesystem-safe")
  func slugsAreSafe() {
    #expect(Collection(name: "Work / Stuff").slug == "work-stuff")
    #expect(Collection(name: "a/b\\c:d").slug == "a-b-c-d")
    #expect(Collection(name: "///").slug == "collection")
    #expect(Collection(name: "").slug == "collection")
    #expect(!Collection(name: "../../etc/passwd").slug.contains("/"))
    #expect(!Collection(name: "../../etc/passwd").slug.contains("."))
  }

  @Test("A store with no sidecar file still works")
  func missingSidecar() async throws {
    let store = CollectionStore(sidecarURL: nil)
    #expect(await store.collections.isEmpty)
    await store.setPinned(true, clipID: UUID())
    // save() is a no-op with no path configured, rather than trapping.
    try await store.save()
  }
}