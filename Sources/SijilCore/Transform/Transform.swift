import Foundation

/// A text transform the user can apply to a clip.
///
/// Transforms are pure functions over text, which keeps them trivially testable
/// and means the expensive ones can move off the main actor without ceremony.
/// Identity is `id`, so two catalogue entries with the same id are equal even
/// though their closures differ.
public struct Transform: Sendable, Identifiable {
  public let id: String
  public let name: String
  public let category: Category
  public let detail: String
  let apply: @Sendable (String) -> String?

  public init(
    id: String,
    name: String,
    category: Category,
    detail: String,
    apply: @escaping @Sendable (String) -> String?
  ) {
    self.id = id
    self.name = name
    self.category = category
    self.detail = detail
    self.apply = apply
  }

  public enum Category: String, Sendable, CaseIterable, Codable {
    case caseConvert = "Case"
    case text = "Text"
    case encode = "Encode"
    case escape = "Escape"
    case web = "Web"
    case number = "Number"
    case lines = "Lines"
    case sort = "Sort"
    case format = "Format"
    case path = "Path"

    public var displayName: String { rawValue }
  }

  /// Returns nil when the transform does not apply to this input, so the UI can
  /// disable rather than silently mangle text.
  public func run(_ input: String) -> String? {
    guard !input.isEmpty else { return nil }
    return apply(input)
  }
}

extension Transform: Equatable {
  public static func == (lhs: Transform, rhs: Transform) -> Bool {
    lhs.id == rhs.id
  }
}

extension Transform: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
