import Foundation

/// Storage contract for clipboard history.
///
/// Two implementations exist: `SQLiteClipStore` (the queryable index, always
/// present) and the vault writer (the durable, synced record). They are not
/// master and slave — both receive every capture — so this protocol is
/// deliberately small and synchronous.
public protocol ClipStore: Sendable {
  /// Records `item`, collapsing it into an existing row when the content hash
  /// matches. Returns the stored row, which may predate `item`.
  func record(_ item: ClipItem) throws -> ClipItem

  func item(id: UUID) throws -> ClipItem?
  func item(matchingContentHash hash: String) throws -> ClipItem?
  func recent(limit: Int, includeUnpinnedOnly: Bool) throws -> [ClipItem]

  /// Full-text search. Substring matching is supported so partial identifiers
  /// from code snippets are findable.
  func search(_ query: String, limit: Int) throws -> [ClipItem]

  func setPinned(_ pinned: Bool, id: UUID) throws
  func markUsed(id: UUID) throws
  func setCollection(_ collection: String?, id: UUID) throws
  func delete(id: UUID) throws
  func deleteAll(includingPinned: Bool) throws -> [UUID]

  /// Rows never yet written to the vault, oldest first.
  func pendingExport(limit: Int) throws -> [ClipItem]
  func markExported(ids: [UUID], at date: Date) throws

  /// Applies retention. Returns the ids that were removed.
  func prune(policy: RetentionPolicy, now: Date) throws -> [UUID]

  func count() throws -> Int
  func byteSize() throws -> Int64
}

/// Retention keeps synced-folder churn bounded — file count is the primary
/// reliability risk for a vault living in Dropbox or iCloud Drive.
public struct RetentionPolicy: Sendable, Equatable, Codable {
  /// Full-fidelity items older than this are dropped entirely.
  public var fullFidelityWindow: TimeInterval = 30 * 24 * 3600
  /// Textual items older than this are trimmed. Nil means unbounded.
  public var textTailWindow: TimeInterval? = 365 * 24 * 3600
  /// Hard ceiling on total rows, applied after the age rules.
  public var maximumItems: Int? = 20_000
  /// Never drop pinned items or anything in a collection.
  public var preservesPinned: Bool = true

  public init(
    fullFidelityWindow: TimeInterval = 30 * 24 * 3600,
    textTailWindow: TimeInterval? = 365 * 24 * 3600,
    maximumItems: Int? = 20_000,
    preservesPinned: Bool = true
  ) {
    self.fullFidelityWindow = fullFidelityWindow
    self.textTailWindow = textTailWindow
    self.maximumItems = maximumItems
    self.preservesPinned = preservesPinned
  }

  /// Keep everything. Useful for the vault being the only record.
  public static let unlimited = RetentionPolicy(
    fullFidelityWindow: .greatestFiniteMagnitude,
    textTailWindow: nil,
    maximumItems: nil
  )
}