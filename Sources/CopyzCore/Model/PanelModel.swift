import Foundation

/// Selection state for the clipboard panel.
///
/// Pure logic with no AppKit or SwiftUI dependency, so the parts most likely to
/// be subtly wrong — clamping at the ends of the list, and never leaving the
/// selection dangling on a deleted row — are unit-testable.
@MainActor
@Observable
public final class PanelModel {
  public private(set) var items: [ClipItem] = []
  public var query = ""
  public var selection: UUID?
  /// True while the shortcut is held, which switches to Quick Mode.
  public var isQuickMode = false

  public init() {}

  public var selectedItem: ClipItem? {
    guard let selection else { return items.first }
    return items.first { $0.id == selection } ?? items.first
  }

  /// Clamped movement. Returns whether the selection actually changed, so the
  /// caller can skip pointless UI work at the ends of the list.
  @discardableResult
  public func moveSelection(by offset: Int) -> Bool {
    guard !items.isEmpty else { return false }
    let current = selection.flatMap { id in items.firstIndex { $0.id == id } } ?? -1
    let next = min(max(current + offset, 0), items.count - 1)
    guard next != current else { return false }
    selection = items[next].id
    return true
  }

  public func removeItem(_ id: UUID) {
    items.removeAll { $0.id == id }
    // Keep the selection on a real row rather than leaving it dangling.
    if selection == id || !items.contains(where: { $0.id == selection }) {
      selection = items.first?.id
    }
  }

  public func replaceItems(_ newItems: [ClipItem]) {
    items = newItems
    if !newItems.contains(where: { $0.id == selection }) {
      selection = newItems.first?.id
    }
  }
}