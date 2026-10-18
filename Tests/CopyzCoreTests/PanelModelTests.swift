import AppKit
import Foundation
import Testing

@testable import CopyzCore
@testable import CopyzPaste

/// Exercises the pure logic behind the panel: selection movement, key mapping,
/// and filter matching. The view itself needs a running NSApplication, so these
/// cover the parts where a mistake would be invisible in manual testing.
@Suite("Panel selection model")
struct PanelModelTests {
  private func item(_ name: String) -> ClipItem {
    ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data(name.utf8)),
    ])
  }

  @MainActor
  @Test("Movement clamps at both ends")
  func movementClamps() {
    let model = PanelModel()
    model.replaceItems([item("a"), item("b"), item("c")])
    #expect(model.selection == model.items[0].id)

    // Cannot move up from the top.
    #expect(model.moveSelection(by: -1) == false)
    #expect(model.selection == model.items[0].id)

    #expect(model.moveSelection(by: 1) == true)
    #expect(model.selection == model.items[1].id)

    // Cannot move past the bottom.
    model.moveSelection(by: 1)
    #expect(model.selection == model.items[2].id)
    #expect(model.moveSelection(by: 1) == false)
    #expect(model.selection == model.items[2].id)
  }

  @MainActor
  @Test("Movement on an empty list is safe")
  func emptyListSafe() {
    let model = PanelModel()
    model.replaceItems([])
    #expect(model.moveSelection(by: 1) == false)
    #expect(model.selectedItem == nil)
  }

  @MainActor
  @Test("Deleting the selected row moves the selection")
  func deleteMovesSelection() {
    let model = PanelModel()
    let items = [item("a"), item("b"), item("c")]
    model.replaceItems(items)
    model.selection = items[1].id

    model.removeItem(items[1].id)
    #expect(model.items.count == 2)
    // Must not still point at the removed row.
    #expect(model.selection != items[1].id)
    #expect(model.items.contains { $0.id == model.selection })
  }

  @MainActor
  @Test("Deleting the last row keeps a valid selection")
  func deleteLastRow() {
    let model = PanelModel()
    let items = [item("a")]
    model.replaceItems(items)
    model.selection = items[0].id

    model.removeItem(items[0].id)
    #expect(model.items.isEmpty)
    #expect(model.selection == nil)
    #expect(model.selectedItem == nil)
  }

  @MainActor
  @Test("Replacing items keeps a still-valid selection")
  func replaceKeepsSelection() {
    let model = PanelModel()
    let items = [item("a"), item("b")]
    model.replaceItems(items)
    model.selection = items[1].id

    // Same rows, different order.
    model.replaceItems([items[1], items[0]])
    #expect(model.selection == items[1].id)
  }

  @MainActor
  @Test("Replacing with disjoint items resets the selection")
  func replaceResetsSelection() {
    let model = PanelModel()
    let items = [item("a")]
    model.replaceItems(items)
    model.selection = items[0].id

    model.replaceItems([item("z")])
    #expect(model.selection == model.items[0].id)
  }
}

@Suite("Panel key mapping")
struct PanelKeyMappingTests {
  private func action(
    _ keyCode: UInt16,
    _ modifiers: NSEvent.ModifierFlags = []
  ) -> PanelKeyMonitor.Action? {
    PanelKeyMonitor.action(forKeyCode: keyCode, modifiers: modifiers, characters: nil)
  }

  @Test("Arrow keys move the selection")
  func arrows() {
    #expect(action(126) == .moveSelection(-1))
    #expect(action(125) == .moveSelection(1))
  }

  @Test("Escape dismisses")
  func escapeDismisses() {
    #expect(action(53) == .dismiss)
  }

  @Test("Return commits the selection")
  func returnCommits() {
    #expect(action(36) == .copySelection)
  }

  @Test("Delete keys remove")
  func deleteKeys() {
    #expect(action(51) == .deleteSelection)
    #expect(action(115) == .deleteSelection)
  }

  @Test("Command-P pins")
  func commandPPins() {
    let pinned = PanelKeyMonitor.action(
      forKeyCode: 35,
      modifiers: .command,
      characters: "p"
    )
    #expect(pinned == .togglePinSelection)
  }

  @Test("Unmodified letters are ignored so typing still reaches search")
  func lettersPassThrough() {
    #expect(action(0, []) == nil)
    #expect(
      PanelKeyMonitor.action(
        forKeyCode: 0,
        modifiers: [],
        characters: "a"
      ) == nil
    )
  }

  @Test("Modifier combinations that are not bindings are ignored")
  func nonBindingsIgnored() {
    // ⇧⌘P is not a pin.
    #expect(
      PanelKeyMonitor.action(
        forKeyCode: 35,
        modifiers: [.command, .shift],
        characters: "p"
      ) == nil
    )
    // ⌥⌘P is not a pin.
    #expect(
      PanelKeyMonitor.action(
        forKeyCode: 35,
        modifiers: [.command, .option],
        characters: "p"
      ) == nil
    )
  }

  @Test("Command-modified navigation keys are ignored")
  func commandArrowsIgnored() {
    #expect(action(125, [.command, .shift]) == .moveSelection(1))
    // Return with Command is a dismiss, not a commit.
    #expect(action(36, .command) == .dismiss)
  }
}