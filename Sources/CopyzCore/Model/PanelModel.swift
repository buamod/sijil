import Foundation

/// Selection state for the clipboard panel.
///
/// Pure logic with no AppKit or SwiftUI dependency, so the parts most likely to
/// be subtly wrong — clamping at the ends of the list, and never leaving the
/// selection dangling on a deleted row — are unit-testable.
@MainActor
@Observable
public final class PanelModel {
  /// Which slice of the history the panel is showing.
  public enum Scope: Hashable, Sendable {
    case all
    case pinned
    case locked
    case collection(UUID)

    public var label: String {
      switch self {
      case .all: "All"
      case .pinned: "Pinned"
      case .locked: "Locked"
      case .collection: "Collection"
      }
    }
  }

  /// Everything the panel could show, after search but before the sidebar
  /// filter. Held separately so switching scope is a re-filter rather than a
  /// round trip to SQLite.
  public private(set) var items: [ClipItem] = []
  public var query = ""
  public var selection: UUID?
  /// True while the shortcut is held, which switches to Quick Mode.
  public var isQuickMode = false
  /// Sidebar selection.
  public private(set) var scope: Scope = .all
  /// Collections offered in the sidebar.
  public private(set) var collections: [Collection] = []

  public init() {}

  /// `items` narrowed to the current sidebar scope.
  ///
  /// The arrow keys and the count in the footer both work off this, so a pinned
  /// filter shows only pinned rows rather than a list that looks filtered but
  /// navigates through everything.
  public var visibleItems: [ClipItem] {
    switch scope {
    case .all: items
    case .pinned: items.filter(\.pinned)
    case .locked: items.filter(\.locked)
    case .collection(let id): items.filter { $0.collection == id.uuidString }
    }
  }

  /// The item the user is acting on.
  public var selectedItem: ClipItem? {
    guard let selection else { return visibleItems.first }
    return visibleItems.first { $0.id == selection } ?? visibleItems.first
  }

  /// Scopes that have at least one item, plus every collection.
  ///
  /// Showing an empty bucket that cannot be selected is just noise, but
  /// collections are always listed: an empty one still needs to be selectable
  /// so a clip can be filed into it.
  public var scopes: [(Scope, String)] {
    var result: [(Scope, String)] = []
    if items.contains(where: \.pinned) { result.append((.pinned, "Pinned")) }
    if items.contains(where: \.locked) { result.append((.locked, "Locked")) }
    for collection in collections {
      let count = items.count { $0.collection == collection.id.uuidString }
      result.append((.collection(collection.id), "\(collection.name) (\(count))"))
    }
    return result
  }

  /// Switches scope, reselecting if the current selection is not visible in it.
  ///
  /// Without the reselect the panel would show a filtered list with the
  /// highlight on a row that is no longer there, and the first arrow-key press
  /// would jump somewhere unrelated.
  public func selectScope(_ newScope: Scope) {
    scope = newScope
    if !visibleItems.contains(where: { $0.id == selection }) {
      selection = visibleItems.first?.id
    }
  }

  public func setCollections(_ newCollections: [Collection]) {
    collections = newCollections
    // A collection that was deleted while selected must not stay selected, or
    // the sidebar would highlight a row that no longer exists.
    if case .collection(let id) = scope,
       !newCollections.contains(where: { $0.id == id }) {
      selectScope(.all)
    }
  }

  /// Clamped movement. Returns whether the selection actually changed, so the
  /// caller can skip pointless UI work at the ends of the list.
  @discardableResult
  public func moveSelection(by offset: Int) -> Bool {
    let rows = visibleItems
    guard !rows.isEmpty else { return false }
    let current = selection.flatMap { id in rows.firstIndex { $0.id == id } } ?? -1
    let next = min(max(current + offset, 0), rows.count - 1)
    guard next != current else { return false }
    selection = rows[next].id
    return true
  }

  public func removeItem(_ id: UUID) {
    items.removeAll { $0.id == id }
    // Keep the selection on a real row rather than leaving it dangling.
    if selection == id || !visibleItems.contains(where: { $0.id == selection }) {
      selection = visibleItems.first?.id
    }
  }

  public func replaceItems(_ newItems: [ClipItem]) {
    items = newItems
    if !visibleItems.contains(where: { $0.id == selection }) {
      selection = visibleItems.first?.id
    }
  }
}