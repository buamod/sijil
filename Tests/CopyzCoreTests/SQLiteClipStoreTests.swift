import Foundation
import Testing

@testable import CopyzCore

@Suite("SQLiteClipStore")
struct SQLiteClipStoreTests {
  private func makeStore() throws -> SQLiteClipStore {
    try SQLiteClipStore(inMemory: true)
  }

  private func textItem(
    _ text: String,
    source: String? = nil,
    at date: Date = Date(),
    pinned: Bool = false
  ) -> ClipItem {
    ClipItem(
      createdAt: date,
      sourceBundleID: source,
      sourceAppName: source,
      contents: [ClipContent(type: PasteboardType.string.rawValue, value: Data(text.utf8))],
      pinned: pinned
    )
  }

  @Test("Round-trips an item")
  func roundTrip() throws {
    let store = try makeStore()
    let original = textItem("hello world", source: "com.apple.Safari")
    let stored = try store.record(original)

    let fetched = try #require(try store.item(id: original.id))
    #expect(fetched.title == original.title)
    #expect(fetched.plainText == "hello world")
    #expect(fetched.sourceBundleID == "com.apple.Safari")
    #expect(stored.id == original.id)
  }

  @Test("Identical content collapses to one row and bumps use count")
  func dedupesByContentHash() throws {
    let store = try makeStore()
    let first = textItem("duplicate")
    let second = textItem("duplicate")

    try store.record(first)
    let merged = try store.record(second)

    #expect(try store.count() == 1)
    #expect(merged.id == first.id)
    #expect(merged.useCount == 2)
  }

  @Test("Different content stays separate")
  func distinctContentStored() throws {
    let store = try makeStore()
    try store.record(textItem("one"))
    try store.record(textItem("two"))
    #expect(try store.count() == 2)
  }

  @Test("Search finds substrings, not just word prefixes")
  func searchIsSubstringBased() throws {
    let store = try makeStore()
    try store.record(textItem("func createTable(named name: String) async throws { }"))
    try store.record(textItem("let total = items.reduce(0) { $0 + $1 }"))

    let hits = try store.search("createTab", limit: 10)
    #expect(hits.count == 1)
    #expect(hits.first?.plainText?.contains("createTable") == true)
  }

  @Test("Search under three characters returns nothing")
  func searchIgnoresShortQueries() throws {
    let store = try makeStore()
    try store.record(textItem("abcdef"))
    #expect(try store.search("ab", limit: 10).isEmpty)
  }

  @Test("Search treats input as literal text, not FTS syntax")
  func searchIsLiteral() throws {
    let store = try makeStore()
    try store.record(textItem("a quoted phrase"))
    // Unbalanced quotes would be a parse error if user input reached the parser raw.
    #expect(try store.search("\"quoted", limit: 10).count == 1)
  }

  @Test("Pinned items sort ahead of recent ones")
  func pinnedSortsFirst() throws {
    let store = try makeStore()
    try store.record(textItem("older pinned", at: Date(timeIntervalSince1970: 1_000), pinned: true))
    try store.record(textItem("newer unpinned", at: Date(timeIntervalSince1970: 9_000)))

    let recent = try store.recent(limit: 10, includeUnpinnedOnly: false)
    #expect(recent.first?.title == "older pinned")
    #expect(recent.count == 2)
  }

  @Test("Pinned items are exempt from retention")
  func prunePreservesPinned() throws {
    let store = try makeStore()
    let old = Date(timeIntervalSince1970: 1_000)
    try store.record(textItem("keep me", at: old, pinned: true))
    try store.record(textItem("drop me", at: old))

    let removed = try store.prune(
      policy: RetentionPolicy(fullFidelityWindow: 10, textTailWindow: 5),
      now: Date(timeIntervalSince1970: 10_000)
    )

    #expect(removed.count == 1)
    let remaining = try store.recent(limit: 10, includeUnpinnedOnly: false)
    #expect(remaining.count == 1)
    #expect(remaining.first?.title == "keep me")
  }

  @Test("Collections are exempt from retention")
  func prunePreservesCollections() throws {
    let store = try makeStore()
    let old = Date(timeIntervalSince1970: 1_000)
    var collected = textItem("in a collection", at: old)
    collected.collection = "work"
    try store.record(collected)
    try store.record(textItem("loose", at: old))

    _ = try store.prune(
      policy: RetentionPolicy(fullFidelityWindow: 10, textTailWindow: 5),
      now: Date(timeIntervalSince1970: 10_000)
    )
    #expect(try store.count() == 1)
  }

  @Test("Maximum item ceiling applies after age rules")
  func pruneEnforcesCeiling() throws {
    let store = try makeStore()
    for index in 0..<10 {
      try store.record(textItem("item \(index)", at: Date(timeIntervalSince1970: Double(1_000 + index))))
    }

    let removed = try store.prune(
      policy: RetentionPolicy(
        fullFidelityWindow: .greatestFiniteMagnitude,
        textTailWindow: nil,
        maximumItems: 4
      ),
      now: Date(timeIntervalSince1970: 10_000)
    )

    #expect(removed.count == 6)
    #expect(try store.count() == 4)
  }

  @Test("Deleted items leave the search index")
  func deleteRemovesFromIndex() throws {
    let store = try makeStore()
    let item = textItem("ephemeral note")
    try store.record(item)
    #expect(try store.search("ephemeral", limit: 5).count == 1)

    try store.delete(id: item.id)
    #expect(try store.search("ephemeral", limit: 5).isEmpty)
    #expect(try store.item(id: item.id) == nil)
  }

  @Test("Delete-all leaves pinned items unless asked")
  func deleteAllRespectsPinned() throws {
    let store = try makeStore()
    try store.record(textItem("safe", pinned: true))
    try store.record(textItem("gone"))

    _ = try store.deleteAll(includingPinned: false)
    #expect(try store.count() == 1)

    _ = try store.deleteAll(includingPinned: true)
    #expect(try store.count() == 0)
  }

  @Test("Export tracking separates pending from written")
  func tracksExportState() throws {
    let store = try makeStore()
    let item = textItem("needs writing")
    try store.record(item)

    let pending = try store.pendingExport(limit: 10)
    #expect(pending.count == 1)

    try store.markExported(ids: [item.id])
    #expect(try store.pendingExport(limit: 10).isEmpty)
  }

  @Test("Multiple typed blobs on one item all survive a round trip")
  func multiRepresentationRoundTrip() throws {
    let store = try makeStore()
    let item = ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data("https://example.com".utf8)),
      ClipContent(type: PasteboardType.html.rawValue, value: Data("<a href='x'>example</a>".utf8)),
    ])

    try store.record(item)
    let fetched = try #require(try store.item(id: item.id))
    #expect(fetched.contents.count == 2)
    #expect(fetched.kind == .link)
  }

  @Test("Binary payloads are pruned once past the fidelity window")
  func binaryPrunedByFidelityWindow() throws {
    let store = try makeStore()
    let old = Date(timeIntervalSince1970: 1_000)
    let image = ClipItem(
      createdAt: old,
      contents: [ClipContent(type: PasteboardType.png.rawValue, value: Data([0x89, 0x50, 0x4E, 0x47]))]
    )
    #expect(image.kind == .image)
    try store.record(image)

    let removed = try store.prune(
      policy: RetentionPolicy(fullFidelityWindow: 10, textTailWindow: nil, maximumItems: nil),
      now: Date(timeIntervalSince1970: 10_000)
    )
    #expect(removed.count == 1)
    #expect(try store.count() == 0)
  }
}