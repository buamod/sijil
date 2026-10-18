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

  /// Whether the last selection change came from the keyboard.
  ///
  /// The view needs this to decide whether to *animate* scrolling. Animating on
  /// a mouse click is what makes clicking feel laggy: the row highlights, but
  /// the list is still easing toward a centred position. Keyboard navigation
  /// wants the animation, because the selection can jump a long way at once.
  public private(set) var selectionMovedByKeyboard = false

  /// `items` narrowed to the current sidebar scope.
  ///
  /// Cached rather than computed: SwiftUI reads this from the `ForEach`, the
  /// footer count, and `selectedItem` on every render, and each read would
  /// otherwise be a fresh O(n) filter pass over up to 500 rows.
  public private(set) var visibleItems: [ClipItem] = []

  /// Sidebar buckets with their counts. Cached for the same reason.
  public private(set) var scopes: [(Scope, String)] = []

  /// Pre-rendered timestamps, keyed by clip id.
  ///
  /// `Text(date, format: .relative)` is deceptively expensive in a list: each one
  /// builds a `FormatStyle` and schedules its own refresh, so a few hundred rows
  /// mean a few hundred timers and a full re-render cycle every minute. Formatting
  /// once per reload turns that into a single O(n) pass.
  public private(set) var timestamps: [UUID: String] = [:]

  /// Pre-rendered timestamp for a row.
  public func timestamp(for item: ClipItem) -> String {
    timestamps[item.id] ?? Self.timelineLabel(for: item.createdAt)
  }

  /// Time for today, date for anything older.
  ///
  /// Cheaper than a relative style and more useful in a list you scan quickly:
  /// "14:32" says what you want when you just copied something, and "18 Oct"
  /// says what you want when you are looking for something from last week.
  static func timelineLabel(for date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      return date.formatted(date: .omitted, time: .shortened)
    }
    if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
      return date.formatted(.dateTime.day().month(.abbreviated))
    }
    return date.formatted(.dateTime.day().month(.abbreviated).year())
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
  private static func computeScopes(
    items: [ClipItem], collections: [Collection]
  ) -> [(Scope, String)] {
    var result: [(Scope, String)] = []
    if items.contains(where: \.pinned) { result.append((.pinned, "Pinned")) }
    if items.contains(where: \.locked) { result.append((.locked, "Locked")) }

    // One pass to tally, rather than a rescan per collection.
    var counts: [UUID: Int] = [:]
    for item in items {
      guard let raw = item.collection, let id = UUID(uuidString: raw) else { continue }
      counts[id, default: 0] += 1
    }
    for collection in collections {
      result.append(
        (.collection(collection.id), "\(collection.name) (\(counts[collection.id] ?? 0))"))
    }
    return result
  }

  /// Recomputes the derived arrays. Called from every mutation rather than on
  /// read, so the view never pays for a filter pass mid-layout.
  private func refreshDerived() {
    switch scope {
    case .all: visibleItems = items
    case .pinned: visibleItems = items.filter(\.pinned)
    case .locked: visibleItems = items.filter(\.locked)
    case .collection(let id):
      let wanted = id.uuidString
      visibleItems = items.filter { $0.collection == wanted }
    }
    scopes = Self.computeScopes(items: items, collections: collections)
    timestamps = Dictionary(
      uniqueKeysWithValues: items.map { ($0.id, Self.timelineLabel(for: $0.createdAt)) }
    )
  }

  /// Switches scope, reselecting if the current selection is not visible in it.
  ///
  /// Without the reselect the panel would show a filtered list with the
  /// highlight on a row that is no longer there, and the first arrow-key press
  /// would jump somewhere unrelated.
  public func selectScope(_ newScope: Scope) {
    scope = newScope
    refreshDerived()
    if !visibleItems.contains(where: { $0.id == selection }) {
      selection = visibleItems.first?.id
    }
  }

  public func setCollections(_ newCollections: [Collection]) {
    collections = newCollections
    // A collection that was deleted while selected must not stay selected, or
    // the sidebar would highlight a row that no longer exists.
    if case .collection(let id) = scope,
      !newCollections.contains(where: { $0.id == id })
    {
      scope = .all
    }
    refreshDerived()
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
    selectionMovedByKeyboard = true
    return true
  }

  /// Selects a row directly, as a click does.
  ///
  /// Separate from assigning `selection` so the caller can tell a click from a
  /// keypress without inspecting how the change was made.
  public func select(_ id: UUID) {
    guard selection != id else { return }
    selection = id
    selectionMovedByKeyboard = false
  }

  public func removeItem(_ id: UUID) {
    items.removeAll { $0.id == id }
    refreshDerived()
    // Keep the selection on a real row rather than leaving it dangling.
    if selection == id || !visibleItems.contains(where: { $0.id == selection }) {
      selection = visibleItems.first?.id
    }
  }

  public func replaceItems(_ newItems: [ClipItem]) {
    items = newItems
    refreshDerived()
    if !visibleItems.contains(where: { $0.id == selection }) {
      selection = visibleItems.first?.id
    }
  }
}
