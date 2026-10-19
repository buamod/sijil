import Foundation
import Testing

@testable import SijilCore

/// The sidebar is pure logic on purpose: the interesting failures — a selection
/// stranded on a hidden row, arrow keys navigating rows the user cannot see — are
/// exactly the kind that only show up as "it feels wrong" in a running app.
@MainActor
@Suite("Panel sidebar")
struct PanelSidebarTests {
  private func item(
    text: String,
    pinned: Bool = false,
    locked: Bool = false,
    collection: UUID? = nil
  ) -> ClipItem {
    ClipItem(
      contents: [
        ClipContent(type: PasteboardType.string.rawValue, value: Data(text.utf8))
      ],
      pinned: pinned,
      locked: locked,
      collection: collection?.uuidString
    )
  }

  private func collection(_ name: String) -> Collection {
    Collection(name: name)
  }

  // MARK: - Filtering

  @Test("All shows everything")
  func allShowsEverything() {
    let model = PanelModel()
    model.replaceItems([
      item(text: "a"),
      item(text: "b", pinned: true),
      item(text: "c", locked: true),
    ])
    #expect(model.visibleItems.count == 3)
  }

  @Test("Pinned shows only pinned items")
  func pinnedFilters() {
    let model = PanelModel()
    model.replaceItems([
      item(text: "plain"),
      item(text: "pinned", pinned: true),
      item(text: "locked", locked: true),
    ])
    model.selectScope(.pinned)
    #expect(model.visibleItems.map(\.title) == ["pinned"])
  }

  @Test("Locked shows only locked items")
  func lockedFilters() {
    let model = PanelModel()
    model.replaceItems([
      item(text: "plain"),
      item(text: "locked", locked: true),
    ])
    model.selectScope(.locked)
    #expect(model.visibleItems.map(\.title) == ["locked"])
  }

  @Test("A collection shows only its members")
  func collectionFilters() {
    let work = collection("Work")
    let personal = collection("Personal")
    let model = PanelModel()
    model.setCollections([work, personal])
    model.replaceItems([
      item(text: "in work", collection: work.id),
      item(text: "in personal", collection: personal.id),
      item(text: "loose"),
    ])

    model.selectScope(.collection(work.id))
    #expect(model.visibleItems.map(\.title) == ["in work"])
  }

  // MARK: - Selection coherence

  @Test("Switching scope moves the selection off a hidden row")
  func selectionFollowsScope() {
    let model = PanelModel()
    model.replaceItems([
      item(text: "plain"),
      item(text: "pinned", pinned: true),
    ])
    model.selectScope(.all)
    #expect(model.selectedItem?.title == "plain")

    model.selectScope(.pinned)
    // The old selection is not in this scope, so it must not linger.
    #expect(model.selectedItem?.title == "pinned")
    #expect(model.visibleItems.contains { $0.id == model.selection })
  }

  @Test("Arrow keys navigate only visible rows")
  func arrowKeysRespectScope() {
    let model = PanelModel()
    model.replaceItems([
      item(text: "pinned one", pinned: true),
      item(text: "plain one"),
      item(text: "pinned two", pinned: true),
      item(text: "plain two"),
    ])
    model.selectScope(.pinned)

    #expect(model.selectedItem?.title == "pinned one")
    model.moveSelection(by: 1)
    #expect(model.selectedItem?.title == "pinned two")
    // Clamped at the end rather than wrapping onto a plain item.
    model.moveSelection(by: 1)
    #expect(model.selectedItem?.title == "pinned two")
    model.moveSelection(by: -1)
    #expect(model.selectedItem?.title == "pinned one")
  }

  @Test("Deleting the selected row keeps the selection valid")
  func deleteKeepsSelectionValid() {
    let model = PanelModel()
    model.replaceItems([
      item(text: "one", pinned: true),
      item(text: "two", pinned: true),
    ])
    model.selectScope(.pinned)
    let target = try! #require(model.selectedItem)
    model.removeItem(target.id)

    #expect(model.visibleItems.count == 1)
    #expect(model.selection == model.visibleItems.first?.id)
    #expect(model.selectedItem?.title == "two")
  }

  @Test("Deleting the last row in a scope clears the selection")
  func emptyScopeClearsSelection() {
    let model = PanelModel()
    model.replaceItems([item(text: "only", pinned: true)])
    model.selectScope(.pinned)
    #expect(model.selection != nil)

    model.removeItem(model.visibleItems[0].id)
    #expect(model.visibleItems.isEmpty)
    #expect(model.selectedItem == nil)
  }

  @Test("A deleted collection drops out of the sidebar")
  func deletedCollectionDropsScope() {
    let work = collection("Work")
    let model = PanelModel()
    model.setCollections([work])
    model.replaceItems([item(text: "in work", collection: work.id)])
    model.selectScope(.collection(work.id))
    #expect(model.scope == .collection(work.id))

    model.setCollections([])
    // Staying selected would highlight a sidebar row that no longer exists.
    #expect(model.scope == .all)
    #expect(model.visibleItems.count == 1)
  }

  // MARK: - Sidebar contents

  @Test("Empty buckets are not offered, but empty collections are")
  func scopesReflectContent() {
    let empty = collection("Empty")
    let model = PanelModel()
    model.setCollections([empty])
    model.replaceItems([item(text: "pinned", pinned: true)])

    let labels = model.scopes.map(\.1)
    #expect(labels.contains("Pinned"))
    #expect(!labels.contains("Locked"), "no locked items, so no Locked bucket")
    // An empty collection must stay selectable so a clip can be filed into it.
    #expect(labels.contains("Empty (0)"))
  }

  @Test("Collection counts reflect what is currently shown")
  func collectionCountsMatch() {
    let work = collection("Work")
    let model = PanelModel()
    model.setCollections([work])
    model.replaceItems([
      item(text: "a", collection: work.id),
      item(text: "b", collection: work.id),
      item(text: "c", locked: true, collection: work.id),
    ])

    let entry = try! #require(model.scopes.first { $0.0 == .collection(work.id) })
    #expect(entry.1 == "Work (3)")

    // Narrowing the scope narrows the count, so the number stays honest.
    model.selectScope(.locked)
    #expect(model.visibleItems.count == 1)
  }

  @Test("A model with nothing in it behaves")
  func emptyModelIsSafe() {
    let model = PanelModel()
    #expect(model.visibleItems.isEmpty)
    #expect(model.selectedItem == nil)
    #expect(model.moveSelection(by: 1) == false)
    #expect(model.moveSelection(by: -1) == false)
    model.selectScope(.pinned)
    #expect(model.visibleItems.isEmpty)
  }

  @Test("Switching to a scope with no items clears the selection")
  func switchToEmptyScope() {
    let model = PanelModel()
    model.replaceItems([item(text: "plain")])
    model.selectScope(.all)
    #expect(model.selection != nil)

    model.selectScope(.locked)
    #expect(model.selection == nil)
    #expect(model.selectedItem == nil)
  }

  @Test("Replacing items under an active scope keeps the selection valid")
  func replaceItemsUnderScope() {
    let model = PanelModel()
    model.setCollections([collection("Work")])
    model.replaceItems([item(text: "a", collection: UUID())])
    model.selectScope(.pinned)
    model.selection = nil

    // A reload that no longer contains pinned items must not leave a stale id.
    model.replaceItems([item(text: "b"), item(text: "c")])
    #expect(model.selection == model.visibleItems.first?.id)
  }
}
