import Foundation
import Testing

@testable import SijilCore

@Suite("VaultStore")
struct VaultStoreTests {
  private func makeStack() throws -> (SQLiteClipStore, VaultStore, URL) {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "sijil-stack-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try SQLiteClipStore(inMemory: true)
    let writer = VaultWriter(rootURL: root)
    return (store, VaultStore(store: store, writer: writer), root)
  }

  private func cleanup(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
  }

  private func textItem(_ text: String) -> ClipItem {
    ClipItem(contents: [ClipContent(type: PasteboardType.string.rawValue, value: Data(text.utf8))])
  }

  @Test("Flush writes pending rows and clears the pending set")
  func flushExports() async throws {
    let (store, vault, root) = try makeStack()
    defer { cleanup(root) }
    try await vault.prepare()

    _ = try store.record(textItem("export me"))
    #expect(try store.pendingExport(limit: 10).count == 1)

    let written = await vault.flushNow()
    #expect(written == 1)
    #expect(try store.pendingExport(limit: 10).isEmpty)
  }

  @Test("A second flush writes nothing new")
  func flushIsIdempotent() async throws {
    let (store, vault, root) = try makeStack()
    defer { cleanup(root) }
    try await vault.prepare()

    _ = try store.record(textItem("only once"))
    _ = await vault.flushNow()
    #expect(await vault.flushNow() == 0)
  }

  @Test("Import pulls vault notes into a fresh index")
  func importReconstructsIndex() async throws {
    let (store, vault, root) = try makeStack()
    defer { cleanup(root) }
    try await vault.prepare()

    _ = try store.record(textItem("recoverable"))
    _ = await vault.flushNow()

    // Simulate losing the index entirely: no tombstones, because a lost
    // database is not a user delete.
    _ = try store.deleteAll(includingPinned: true, tombstone: false)
    #expect(try store.count() == 0)

    let imported = await vault.importFromVault()
    #expect(imported == 1)
    #expect(try store.count() == 1)
    #expect(try store.search("recoverable", limit: 5).count == 1)
  }

  @Test("Import is idempotent")
  func importIsIdempotent() async throws {
    let (store, vault, root) = try makeStack()
    defer { cleanup(root) }
    try await vault.prepare()

    _ = try store.record(textItem("no duplicates"))
    _ = await vault.flushNow()
    _ = try store.deleteAll(includingPinned: true, tombstone: false)

    #expect(await vault.importFromVault() == 1)
    #expect(await vault.importFromVault() == 0)
    #expect(try store.count() == 1)
  }

  @Test("Full round trip survives index loss")
  func fullRoundTrip() async throws {
    let (store, vault, root) = try makeStack()
    defer { cleanup(root) }
    try await vault.prepare()

    for index in 0..<5 {
      _ = try store.record(textItem("item \(index)"))
    }
    _ = await vault.flushNow()

    _ = try store.deleteAll(includingPinned: true, tombstone: false)
    _ = try await vault.rebuildIndex()
    #expect(try store.count() == 5)
  }

  @Test("Imported rows are not re-exported")
  func importedRowsNotReExported() async throws {
    let (store, vault, root) = try makeStack()
    defer { cleanup(root) }
    try await vault.prepare()

    _ = try store.record(textItem("from vault"))
    _ = await vault.flushNow()
    _ = try store.deleteAll(includingPinned: true, tombstone: false)
    _ = await vault.importFromVault()

    // If import failed to mark them exported, this flush would rewrite them.
    #expect(try store.pendingExport(limit: 10).isEmpty)
  }

  @Test("A flush beyond the first batch still completes")
  func flushHandlesMoreThanOneBatch() async throws {
    let (store, vault, root) = try makeStack()
    defer { cleanup(root) }
    try await vault.prepare()

    // The batch size is 200, so this forces the loop to iterate.
    for index in 0..<250 {
      _ = try store.record(textItem("bulk item \(index)"))
    }

    let written = await vault.flushNow()
    #expect(written == 250)
    #expect(try store.pendingExport(limit: 10).isEmpty)
  }

  @Test("An unreachable vault leaves rows queued for later")
  func unreachableVaultDoesNotLoseRows() async throws {
    let store = try SQLiteClipStore(inMemory: true)
    // A path whose parent is a regular file can never be created.
    let blocker = FileManager.default.temporaryDirectory
      .appending(path: "sijil-block-\(UUID().uuidString)")
    try Data("file".utf8).write(to: blocker)
    defer { try? FileManager.default.removeItem(at: blocker) }

    let vault = VaultStore(
      store: store,
      writer: VaultWriter(rootURL: blocker.appending(path: "Vault", directoryHint: .isDirectory))
    )

    _ = try store.record(textItem("still captured"))
    #expect(await vault.flushNow() == 0)
    // The clip is still in SQLite and still queued, which is the point.
    #expect(try store.pendingExport(limit: 10).count == 1)
    #expect(try store.count() == 1)
  }

  @Test("writeNow persists a pin change without waiting for the debounce")
  func writeNowExportsMetadata() async throws {
    let (store, vault, root) = try makeStack()
    defer { cleanup(root) }
    try await vault.prepare()

    let item = textItem("pin me")
    try store.record(item)
    try store.markExported(ids: [item.id])

    try store.setPinned(true, id: item.id)
    guard let updated = try store.item(id: item.id) else {
      Issue.record("item vanished")
      return
    }
    await vault.writeNow(updated)

    let decoded = await vault.readAll()
    #expect(decoded.first?.pinned == true)
  }
}
