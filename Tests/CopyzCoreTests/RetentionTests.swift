import Foundation
import Testing

@testable import CopyzCore

/// Retention is the knob that decides whether a synced folder stays usable, so
/// the edge cases around it are worth pinning down.
@Suite("Retention policy")
struct RetentionTests {
  @Test("Default policy is bounded on both axes")
  func defaults() {
    let policy = RetentionPolicy()
    #expect(policy.fullFidelityWindow == 30 * 24 * 3600)
    // Compare with a tolerance: the literal is an Int and the property a Double.
    let year = 365 * 24 * 3600
    #expect(abs((policy.textTailWindow ?? 0) - Double(year)) < 1)
    #expect(policy.maximumItems == 20_000)
    #expect(policy.preservesPinned)
  }

  @Test("Unlimited policy disables every bound")
  func unlimited() {
    let policy = RetentionPolicy.unlimited
    #expect(policy.fullFidelityWindow.isInfinite == false)
    #expect(policy.fullFidelityWindow > 1_000_000_000_000)
    #expect(policy.textTailWindow == nil)
    #expect(policy.maximumItems == nil)
  }

  @Test("Policy survives a codable round trip")
  func codableRoundTrip() throws {
    let policy = RetentionPolicy(
      fullFidelityWindow: 86_400,
      textTailWindow: 172_800,
      maximumItems: 500,
      preservesPinned: false
    )
    let data = try JSONEncoder().encode(policy)
    let decoded = try JSONDecoder().decode(RetentionPolicy.self, from: data)
    #expect(decoded == policy)
  }
}

@Suite("Retention against the store")
struct RetentionStoreTests {
  private func makeStore() throws -> SQLiteClipStore {
    try SQLiteClipStore(inMemory: true)
  }

  private func item(
    _ text: String,
    at offset: TimeInterval,
    pinned: Bool = false,
    collection: String? = nil
  ) -> ClipItem {
    ClipItem(
      createdAt: Date(timeIntervalSince1970: offset),
      sourceBundleID: "test",
      contents: [ClipContent(type: PasteboardType.string.rawValue, value: Data(text.utf8))],
      pinned: pinned,
      collection: collection
    )
  }

  @Test("Nothing is pruned inside the window")
  func respectsWindow() throws {
    let store = try makeStore()
    for index in 0..<10 {
      try store.record(item("recent \(index)", at: TimeInterval(10_000 + index)))
    }

    let removed = try store.prune(
      policy: RetentionPolicy(
        fullFidelityWindow: 1_000,
        textTailWindow: 5_000,
        maximumItems: nil
      ),
      now: Date(timeIntervalSince1970: 10_010)
    )
    #expect(removed.isEmpty)
    #expect(try store.count() == 10)
  }

  @Test("Binary payloads are pruned before text at the same age")
  func binaryGoesFirst() throws {
    let store = try makeStore()
    let old = Date(timeIntervalSince1970: 1_000)
    let now = Date(timeIntervalSince1970: 1_000 + 5_000)

    let image = ClipItem(
      createdAt: old,
      contents: [ClipContent(type: PasteboardType.png.rawValue, value: Data([1, 2, 3]))]
    )
    try store.record(image)
    try store.record(item("old text", at: old.timeIntervalSince1970))

    let removed = try store.prune(
      policy: RetentionPolicy(
        fullFidelityWindow: 2_000,
        textTailWindow: 10_000,
        maximumItems: nil
      ),
      now: now
    )

    // Only the image crossed the fidelity window.
    #expect(removed.count == 1)
    #expect(try store.count() == 1)
    #expect(try store.recent(limit: 10, includeUnpinnedOnly: false).first?.plainText == "old text")
  }

  @Test("Ceiling keeps pinned items even when they are oldest")
  func ceilingRespectsPinned() throws {
    let store = try makeStore()
    try store.record(item("ancient pinned", at: 100, pinned: true))
    for index in 0..<5 {
      try store.record(item("item \(index)", at: TimeInterval(1_000 + index)))
    }

    _ = try store.prune(
      policy: RetentionPolicy(
        fullFidelityWindow: .greatestFiniteMagnitude,
        textTailWindow: nil,
        maximumItems: 3
      ),
      now: Date(timeIntervalSince1970: 5_000)
    )

    let remaining = try store.recent(limit: 20, includeUnpinnedOnly: false)
    #expect(remaining.count == 3)
    #expect(remaining.contains { $0.plainText == "ancient pinned" })
  }

  @Test("Pinned items sort ahead of newer unpinned ones when the ceiling bites")
  func ceilingPrefersPinned() throws {
    let store = try makeStore()
    try store.record(item("old pinned", at: 100, pinned: true))
    try store.record(item("newest", at: 900))
    try store.record(item("newer", at: 950))

    _ = try store.prune(
      policy: RetentionPolicy(
        fullFidelityWindow: .greatestFiniteMagnitude,
        textTailWindow: nil,
        maximumItems: 2
      ),
      now: Date(timeIntervalSince1970: 1_000)
    )

    let remaining = try store.recent(limit: 10, includeUnpinnedOnly: false)
    #expect(remaining.count == 2)
    #expect(remaining.contains { $0.plainText == "old pinned" })
  }

  @Test("Pruning an empty store is a no-op")
  func emptyStoreSafe() throws {
    let store = try makeStore()
    let removed = try store.prune(policy: RetentionPolicy(), now: Date())
    #expect(removed.isEmpty)
  }

  @Test("Unlimited policy prunes nothing")
  func unlimitedPrunesNothing() throws {
    let store = try makeStore()
    let old = Date(timeIntervalSince1970: 0)
    for index in 0..<20 {
      try store.record(item("item \(index)", at: old.timeIntervalSince1970))
    }

    let removed = try store.prune(policy: RetentionPolicy.unlimited, now: Date())
    #expect(removed.isEmpty)
    #expect(try store.count() == 20)
  }

  @Test("Pruned rows leave no orphaned content or search entries")
  func pruneCleansUp() throws {
    let store = try makeStore()
    try store.record(item("ephemeral searchable text", at: 1_000))

    let removed = try store.prune(
      policy: RetentionPolicy(
        fullFidelityWindow: 10,
        textTailWindow: 10,
        maximumItems: nil
      ),
      now: Date(timeIntervalSince1970: 100_000)
    )
    #expect(removed.count == 1)
    #expect(try store.search("ephemeral", limit: 5).isEmpty)
    #expect(try store.count() == 0)
  }
}
