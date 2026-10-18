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
  /// Stronger than pinned: exempt from clear-history and from every retention
  /// rule.
  func setLocked(_ locked: Bool, id: UUID) throws
  func markUsed(id: UUID) throws
  func setCollection(_ collection: String?, id: UUID) throws
  /// Deletes a clip and tombstones it, so a sync cannot resurrect it.
  func delete(id: UUID) throws
  /// Removes a row without tombstoning — for discarding the index, not data.
  func purge(id: UUID) throws
  func deleteAll(includingPinned: Bool) throws -> [UUID]
  /// Clears history, optionally tombstoning. Index rebuilds pass `false`.
  func deleteAll(includingPinned: Bool, tombstone: Bool) throws -> [UUID]

  /// Records a deletion so a vault import cannot resurrect the clip.
  ///
  /// Vault import is deliberately read-only, which means a note that still
  /// exists on another synced machine would be re-added forever without this.
  func tombstone(_ id: UUID, at date: Date) throws
  func isTombstoned(_ id: UUID) -> Bool
  func tombstoneCount() throws -> Int
  /// Drops tombstones older than `date`. Returns how many were removed.
  @discardableResult
  func pruneTombstones(olderThan date: Date) throws -> Int

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
  /// Also never drop locked items. Locked is a stronger promise than pinned, so
  /// it is a separate switch rather than reusing `preservesPinned`.
  public var preservesLocked: Bool = true

  public init(
    fullFidelityWindow: TimeInterval = 30 * 24 * 3600,
    textTailWindow: TimeInterval? = 365 * 24 * 3600,
    maximumItems: Int? = 20_000,
    preservesPinned: Bool = true,
    preservesLocked: Bool = true
  ) {
    self.fullFidelityWindow = fullFidelityWindow
    self.textTailWindow = textTailWindow
    self.maximumItems = maximumItems
    self.preservesPinned = preservesPinned
    self.preservesLocked = preservesLocked
  }

  /// Keep everything. Useful for the vault being the only record.
  public static let unlimited = RetentionPolicy(
    fullFidelityWindow: .greatestFiniteMagnitude,
    textTailWindow: nil,
    maximumItems: nil,
    preservesLocked: false
  )
}