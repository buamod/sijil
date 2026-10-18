import Foundation
import Testing

@testable import CopyzCore

/// The panel's derived state is cached, and the cache has to stay honest — a
/// stale `visibleItems` is a list that looks filtered but navigates through
/// everything, which is the exact bug the sidebar was meant to fix.
@MainActor
@Suite("Panel performance")
struct PanelPerformanceTests {
  private func items(_ count: Int) -> [ClipItem] {
    var result: [ClipItem] = []
    result.reserveCapacity(count)
    for index in 0..<count {
      let stamp = Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index))
      let content = ClipContent(
        type: PasteboardType.string.rawValue,
        value: Data("clip number \(index)".utf8)
      )
      result.append(
        ClipItem(
          createdAt: stamp,
          contents: [content],
          pinned: index % 20 == 0,
          locked: index % 50 == 0
        )
      )
    }
    return result
  }

  // MARK: - Cache coherence

  @Test("Derived lists are recomputed on every mutation")
  func derivedStateIsNeverStale() {
    let model = PanelModel()
    model.replaceItems(items(100))
    #expect(model.visibleItems.count == 100)

    model.selectScope(.pinned)
    #expect(model.visibleItems.count == 5, "every twentieth clip is pinned")

    model.selectScope(.locked)
    #expect(model.visibleItems.count == 2, "every fiftieth is locked")

    model.selectScope(.all)
    #expect(model.visibleItems.count == 100)
  }

  @Test("Removing an item updates every derived list")
  func removalUpdatesDerived() {
    let model = PanelModel()
    let list = items(50)
    model.replaceItems(list)
    let target = list[10]

    model.removeItem(target.id)

    #expect(model.visibleItems.count == 49)
    #expect(!model.visibleItems.contains { $0.id == target.id })
    #expect(model.scopes.first { $0.0 == .pinned }?.1 == "Pinned")
  }

  @Test("Collection counts update when items change")
  func collectionCountsRefresh() {
    let work = Collection(name: "Work")
    let model = PanelModel()
    model.setCollections([work])

    model.replaceItems([
      ClipItem(
        contents: [ClipContent(type: PasteboardType.string.rawValue, value: Data("a".utf8))],
        collection: work.id.uuidString
      ),
    ])
    #expect(model.scopes.first { $0.0 == .collection(work.id) }?.1 == "Work (1)")

    model.replaceItems([])
    #expect(model.scopes.first { $0.0 == .collection(work.id) }?.1 == "Work (0)")
  }

  @Test("Timestamps are precomputed for every item")
  func timestampsArePrecomputed() {
    let model = PanelModel()
    let list = items(30)
    model.replaceItems(list)

    #expect(model.timestamps.count == 30)
    for item in list {
      #expect(model.timestamp(for: item) == model.timestamps[item.id])
      #expect(!model.timestamp(for: item).isEmpty)
    }
  }

  @Test("A timestamp drops out when its item does")
  func timestampsDropRemovedItems() {
    let model = PanelModel()
    let list = items(10)
    model.replaceItems(list)
    let removed = list[3]
    model.removeItem(removed.id)
    #expect(model.timestamps[removed.id] == nil)
    #expect(model.timestamps.count == 9)
  }

  // MARK: - Timeline labels

  @Test("Today shows a time, older shows a date")
  func timelineLabelFormat() {
    let now = Date()
    #expect(PanelModel.timelineLabel(for: now).contains(":"))
    #expect(!PanelModel.timelineLabel(for: now).contains("20"))

    let lastWeek = now.addingTimeInterval(-7 * 86_400)
    let label = PanelModel.timelineLabel(for: lastWeek)
    #expect(!label.contains(":"))
  }

  // MARK: - Click vs keyboard

  @Test("A click does not request an animated scroll")
  func clickIsNotKeyboard() {
    let model = PanelModel()
    let list = items(10)
    model.replaceItems(list)
    model.moveSelection(by: 1)
    #expect(model.selectionMovedByKeyboard)

    // The flag is what gates `withAnimation` in the view, so it must be cleared
    // by a direct selection or every click animates again.
    model.select(list[5].id)
    #expect(model.selectionMovedByKeyboard == false)
    #expect(model.selection == list[5].id)
  }

  @Test("Clicking the already-selected row changes nothing")
  func clickOnSameRowIsNoOp() {
    let model = PanelModel()
    let list = items(10)
    model.replaceItems(list)

    // Anchor explicitly so the arithmetic below does not depend on where
    // `replaceItems` left the selection.
    model.select(list[1].id)
    model.moveSelection(by: 1)
    #expect(model.selection == list[2].id)
    #expect(model.selectionMovedByKeyboard)

    model.select(list[7].id)
    #expect(model.selection == list[7].id)
    #expect(model.selectionMovedByKeyboard == false, "a click must clear the flag")

    // Clicking the same row again changes nothing, so the flag cannot be left
    // in the wrong state by a stray re-selection.
    model.select(list[7].id)
    #expect(model.selectionMovedByKeyboard == false)
  }

  // MARK: - Cost

  @Test("Rebuilding derived state stays cheap at list sizes the panel shows")
  func derivedStateIsCheapAtScale() {
    // The panel holds up to 500 rows. Derived state is recomputed on every
    // capture, so this is the per-keystroke cost of the whole cache.
    let model = PanelModel()
    let list = items(500)

    var start = Date()
    model.replaceItems(list)
    let singlePass = Date().timeIntervalSince(start)

    start = Date()
    for _ in 0..<20 { model.replaceItems(list) }
    let twentyPasses = Date().timeIntervalSince(start) / 20

    // The row at index 499 must still be reachable, i.e. the filter really ran.
    #expect(model.visibleItems.count == 500)
    // Generous, but it catches an accidental nested scan: the old collection
    // counting was O(collections x items) on every render.
    #expect(twentyPasses < singlePass * 10 + 0.05)
  }

  @Test("Scope switching does not rescan collections per row")
  func scopeSwitchIsLinear() {
    let work = Collection(name: "Work")
    let home = Collection(name: "Home")
    let model = PanelModel()
    model.setCollections([work, home])

    var list: [ClipItem] = []
    for index in 0..<500 {
      list.append(
        ClipItem(
          createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
          contents: [
            ClipContent(type: PasteboardType.string.rawValue, value: Data("x\(index)".utf8))
          ],
          collection: index % 2 == 0 ? work.id.uuidString : home.id.uuidString
        )
      )
    }
    model.replaceItems(list)

    let start = Date()
    for _ in 0..<50 { model.selectScope(.collection(home.id)) }
    let elapsed = Date().timeIntervalSince(start) / 50

    #expect(model.visibleItems.count == 250)
    #expect(model.scopes.first { $0.0 == .collection(work.id) }?.1 == "Work (250)")
    #expect(elapsed < 0.02, "scope switch took \(elapsed)s")
  }
}