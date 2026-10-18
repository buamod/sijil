import Foundation
import GRDB

/// SQLite-backed history store.
///
/// Raw SQL and manual row mapping rather than `Codable`: benchmarks put GRDB's
/// `Codable` path several times slower than manual decoding for bulk writes,
/// and this database takes one write per clipboard event indefinitely.
///
/// Search uses FTS5 with the `trigram` tokenizer so partial identifiers inside
/// code snippets are findable — word-prefix matching misses `createTab` when
/// the user only remembers `createTable`.
public final class SQLiteClipStore: ClipStore {
  /// `DatabaseWriter` is `DatabaseReader`'s refinement, so this covers both the
  /// on-disk pool (concurrent WAL readers) and the in-memory queue used by
  /// tests.
  private let pool: any DatabaseWriter

  /// On-disk store in Application Support.
  public static func makeDefault() throws -> SQLiteClipStore {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appending(path: "copyz", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return try SQLiteClipStore(path: base.appending(path: "history.sqlite").path)
  }

  public init(path: String) throws {
    var config = Configuration()
    config.prepareDatabase { db in
      // WAL so the UI can read while a write is in flight.
      try db.execute(sql: "PRAGMA journal_mode = WAL")
      try db.execute(sql: "PRAGMA synchronous = NORMAL")
      try db.execute(sql: "PRAGMA foreign_keys = ON")
    }
    let pool = try DatabasePool(path: path, configuration: config)
    try Self.migrator.migrate(pool)
    self.pool = pool
  }

  public init(inMemory: Bool) throws {
    let queue = try DatabaseQueue()
    try Self.migrator.migrate(queue)
    self.pool = queue
  }

  // MARK: - Schema

  private static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.execute(sql: """
        CREATE TABLE clip (
          rowid_pk         INTEGER PRIMARY KEY AUTOINCREMENT,
          id               TEXT    NOT NULL UNIQUE,
          content_hash     TEXT    NOT NULL,
          created_at       REAL    NOT NULL,
          last_used_at     REAL    NOT NULL,
          source_bundle_id TEXT,
          source_app_name  TEXT,
          pinned           INTEGER NOT NULL DEFAULT 0,
          locked           INTEGER NOT NULL DEFAULT 0,
          collection       TEXT,
          use_count        INTEGER NOT NULL DEFAULT 1,
          title            TEXT    NOT NULL DEFAULT '',
          kind             TEXT    NOT NULL,
          exported_at      REAL
        )
        """)

      // Tombstones outlive the rows they refer to: vault import is read-only,
      // so without this a deleted clip is re-added from the note that still
      // exists on every other synced machine.
      try db.execute(sql: """
        CREATE TABLE clip_tombstone (
          id         TEXT PRIMARY KEY,
          deleted_at REAL NOT NULL
        )
        """)
      try db.execute(sql: "CREATE INDEX clip_tombstone_deleted ON clip_tombstone(deleted_at)")

      // Content-addressed dedupe: the same clip copied twice is one row.
      try db.execute(sql: "CREATE UNIQUE INDEX clip_content_hash ON clip(content_hash)")
      try db.execute(sql: "CREATE INDEX clip_created ON clip(created_at DESC)")
      try db.execute(sql: "CREATE INDEX clip_unexported ON clip(exported_at) WHERE exported_at IS NULL")
      try db.execute(sql: "CREATE INDEX clip_locked ON clip(locked) WHERE locked = 1")

      try db.execute(sql: """
        CREATE TABLE clip_content (
          id      INTEGER PRIMARY KEY AUTOINCREMENT,
          clip_id TEXT NOT NULL REFERENCES clip(id) ON DELETE CASCADE,
          type    TEXT NOT NULL,
          value   BLOB NOT NULL
        )
        """)
      try db.execute(sql: "CREATE INDEX clip_content_clip ON clip_content(clip_id)")

      // Standalone FTS5 table rather than external-content: we control writes
      // explicitly, which keeps deletes simple.
      try db.execute(sql: """
        CREATE VIRTUAL TABLE clip_fts USING fts5(
          title,
          body,
          clip_rowid UNINDEXED,
          tokenize = 'trigram'
        )
        """)
    }
    return migrator
  }

  // MARK: - Records

  private struct ClipRow: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "clip"
    var rowidPK: Int64
    var id: String
    var contentHash: String
    var createdAt: Double
    var lastUsedAt: Double
    var sourceBundleID: String?
    var sourceAppName: String?
    var pinned: Int
    var locked: Int
    var collection: String?
    var useCount: Int
    var title: String
    var kind: String

    enum CodingKeys: String, CodingKey {
      case rowidPK = "rowid_pk"
      case id
      case contentHash = "content_hash"
      case createdAt = "created_at"
      case lastUsedAt = "last_used_at"
      case sourceBundleID = "source_bundle_id"
      case sourceAppName = "source_app_name"
      case pinned
      case locked
      case collection
      case useCount = "use_count"
      case title
      case kind
    }
  }

  private struct ContentRow: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "clip_content"
    var clipID: String
    var type: String
    var value: Data

    enum CodingKeys: String, CodingKey {
      case clipID = "clip_id"
      case type, value
    }
  }

  private func makeItem(_ row: ClipRow, contents: [ClipContent]) -> ClipItem {
    ClipItem(
      id: UUID(uuidString: row.id) ?? UUID(),
      createdAt: Date(timeIntervalSince1970: row.createdAt),
      lastUsedAt: Date(timeIntervalSince1970: row.lastUsedAt),
      sourceBundleID: row.sourceBundleID,
      sourceAppName: row.sourceAppName,
      contents: contents,
      pinned: row.pinned != 0,
      locked: row.locked != 0,
      collection: row.collection,
      useCount: row.useCount,
      title: row.title
    )
  }

  /// Hydration always runs against an open `Database`. Calling back into
  /// `pool.read` from inside a `pool.write` would deadlock on the writer.
  private func hydrate(_ rows: [ClipRow], in db: Database) throws -> [ClipItem] {
    guard !rows.isEmpty else { return [] }
    let placeholders = Array(repeating: "?", count: rows.count).joined(separator: ",")
    let contents = try ContentRow.fetchAll(
      db,
      sql: "SELECT clip_id, type, value FROM clip_content WHERE clip_id IN (\(placeholders))",
      arguments: StatementArguments(rows.map(\.id))
    )
    var grouped: [String: [ClipContent]] = [:]
    for row in contents {
      grouped[row.clipID, default: []].append(ClipContent(type: row.type, value: row.value))
    }
    return rows.map { makeItem($0, contents: grouped[$0.id] ?? []) }
  }

  private func hydrate(_ row: ClipRow, in db: Database) throws -> ClipItem {
    try hydrate([row], in: db)[0]
  }

  /// Re-reads one row inside an open write transaction, so callers observe the
  /// post-UPDATE state rather than the snapshot they already held.
  private func reload(_ id: String, in db: Database) throws -> ClipItem {
    let row = try ClipRow
      .filter(Column("id") == id)
      .fetchOne(db)
    guard let row else {
      // Cannot happen: the caller only reaches here with an id it just wrote.
      struct Vanished: Error {}
      throw Vanished()
    }
    return try hydrate(row, in: db)
  }

  // MARK: - ClipStore

  public func record(_ item: ClipItem) throws -> ClipItem {
    let hash = item.contentHash

    return try pool.write { db in
      // Same content already stored — bump usage rather than duplicate.
      if let existing = try ClipRow
        .filter(Column("content_hash") == hash)
        .fetchOne(db)
      {
        try db.execute(
          sql: "UPDATE clip SET last_used_at = ?, use_count = use_count + 1 WHERE rowid_pk = ?",
          arguments: [item.lastUsedAt.timeIntervalSince1970, existing.rowidPK]
        )
        // Re-read so the caller sees the incremented use count rather than the
        // pre-update snapshot.
        return try self.reload(existing.id, in: db)
      }

      // A tombstoned clip must never come back. Vault import is read-only by
      // design, so without this check a delete on one machine is silently
      // undone by the note still sitting in every other machine's vault.
      if try isTombstonedIn(item.id.uuidString, in: db) {
        return item
      }

      try db.execute(
        sql: """
          INSERT INTO clip
            (id, content_hash, created_at, last_used_at, source_bundle_id,
             source_app_name, pinned, locked, collection, use_count, title, kind, exported_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
          """,
        arguments: [
          item.id.uuidString, hash,
          item.createdAt.timeIntervalSince1970, item.lastUsedAt.timeIntervalSince1970,
          item.sourceBundleID, item.sourceAppName,
          item.pinned ? 1 : 0, item.locked ? 1 : 0, item.collection, item.useCount,
          item.title, item.kind.rawValue,
        ]
      )
      let rowidPK = try Int64.fetchOne(db, sql: "SELECT last_insert_rowid()")!

      for content in item.contents {
        try db.execute(
          sql: "INSERT INTO clip_content (clip_id, type, value) VALUES (?, ?, ?)",
          arguments: [item.id.uuidString, content.type, content.value]
        )
      }

      try db.execute(
        sql: "INSERT INTO clip_fts (title, body, clip_rowid) VALUES (?, ?, ?)",
        arguments: [item.title, item.vaultBody, rowidPK]
      )
      return item
    }
  }

  public func item(id: UUID) throws -> ClipItem? {
    try pool.read { db in
      guard let row = try ClipRow.filter(Column("id") == id.uuidString).fetchOne(db) else {
        return nil
      }
      return try self.hydrate(row, in: db)
    }
  }

  public func item(matchingContentHash hash: String) throws -> ClipItem? {
    try pool.read { db in
      guard let row = try ClipRow.filter(Column("content_hash") == hash).fetchOne(db) else {
        return nil
      }
      return try self.hydrate(row, in: db)
    }
  }

  public func recent(limit: Int, includeUnpinnedOnly: Bool = false) throws -> [ClipItem] {
    try pool.read { db in
      var request = ClipRow
        .order(Column("locked").desc, Column("pinned").desc, Column("created_at").desc)
        .limit(limit)
      if includeUnpinnedOnly {
        request = request.filter(Column("pinned") == 0).filter(Column("locked") == 0)
      }
      return try self.hydrate(request.fetchAll(db), in: db)
    }
  }

  public func search(_ query: String, limit: Int) throws -> [ClipItem] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    return try pool.read { db in
      // Trigram tokenization cannot match anything shorter than three
      // characters.
      let terms = trimmed
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { $0.count >= 3 }
        // Quote so FTS5 reads user input as literals; an unbalanced quote would
        // otherwise be a syntax error.
        .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
      guard !terms.isEmpty else { return [] }

      let rows = try ClipRow.fetchAll(
        db,
        sql: """
          SELECT clip.* FROM clip_fts
          JOIN clip ON clip.rowid_pk = clip_fts.clip_rowid
          WHERE clip_fts MATCH ?
          ORDER BY bm25(clip_fts)
          LIMIT ?
          """,
        arguments: [terms.joined(separator: " AND "), limit]
      )
      return try self.hydrate(rows, in: db)
    }
  }

  public func setPinned(_ pinned: Bool, id: UUID) throws {
    try pool.write { db in
      try db.execute(
        sql: "UPDATE clip SET pinned = ? WHERE id = ?",
        arguments: [pinned ? 1 : 0, id.uuidString]
      )
    }
  }

  public func setLocked(_ locked: Bool, id: UUID) throws {
    try pool.write { db in
      try db.execute(
        sql: "UPDATE clip SET locked = ? WHERE id = ?",
        arguments: [locked ? 1 : 0, id.uuidString]
      )
    }
  }

  // MARK: - Tombstones

  /// Records that `id` was deleted, removing any surviving row.
  ///
  /// Removing the row matters: a tombstone left alongside its clip would still
  /// leave that clip searchable, which is not what "deleted" means to a user.
  public func tombstone(_ id: UUID, at date: Date = Date()) throws {
    try pool.write { db in
      try self.deleteRow(id.uuidString, in: db)
      try db.execute(
        sql: "INSERT OR REPLACE INTO clip_tombstone (id, deleted_at) VALUES (?, ?)",
        arguments: [id.uuidString, date.timeIntervalSince1970]
      )
    }
  }

  public func isTombstoned(_ id: UUID) -> Bool {
    (try? pool.read { db in try isTombstonedIn(id.uuidString, in: db) }) ?? false
  }

  public func tombstoneCount() throws -> Int {
    try pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_tombstone") ?? 0 }
  }

  @discardableResult
  public func pruneTombstones(olderThan date: Date) throws -> Int {
    try pool.write { db in
      try db.execute(
        sql: "DELETE FROM clip_tombstone WHERE deleted_at < ?",
        arguments: [date.timeIntervalSince1970]
      )
      return db.changesCount
    }
  }

  private func isTombstonedIn(_ id: String, in db: Database) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: "SELECT EXISTS(SELECT 1 FROM clip_tombstone WHERE id = ?)",
      arguments: [id]
    ) ?? false
  }

  public func markUsed(id: UUID) throws {
    try pool.write { db in
      try db.execute(
        sql: "UPDATE clip SET use_count = use_count + 1, last_used_at = ? WHERE id = ?",
        arguments: [Date().timeIntervalSince1970, id.uuidString]
      )
    }
  }

  public func setCollection(_ collection: String?, id: UUID) throws {
    try pool.write { db in
      try db.execute(
        sql: "UPDATE clip SET collection = ? WHERE id = ?",
        arguments: [collection, id.uuidString]
      )
    }
  }

  /// Deletes a clip and tombstones it, so a sync from another machine cannot
  /// resurrect it.
  public func delete(id: UUID) throws {
    try delete(ids: [id], tombstone: true)
  }

  /// Removes rows without tombstoning.
  ///
  /// Used when the *index* is being discarded rather than the user's data —
  /// a lost database, or an index rebuild. Tombstoning there would make every
  /// recovered clip look deleted and permanently block its re-import.
  public func purge(id: UUID) throws {
    try delete(ids: [id], tombstone: false)
  }

  private func delete(ids: [UUID], tombstone shouldTombstone: Bool) throws {
    guard !ids.isEmpty else { return }
    try pool.write { db in
      let now = Date().timeIntervalSince1970
      for id in ids {
        try self.deleteRow(id.uuidString, in: db)
        if shouldTombstone {
          try db.execute(
            sql: "INSERT OR REPLACE INTO clip_tombstone (id, deleted_at) VALUES (?, ?)",
            arguments: [id.uuidString, now]
          )
        }
      }
    }
  }

  public func deleteAll(includingPinned: Bool) throws -> [UUID] {
    try deleteAll(includingPinned: includingPinned, tombstone: true)
  }

  /// Clears history. Locked items always survive, matching PastePal's
  /// `ZLOCKED`, which is a stronger promise than pinned.
  public func deleteAll(
    includingPinned: Bool,
    tombstone shouldTombstone: Bool
  ) throws -> [UUID] {
    try pool.write { db in
      var request = ClipRow.all()
      if !includingPinned {
        request = request.filter(Column("pinned") == 0)
      }
      request = request.filter(Column("locked") == 0)
      let ids = try request.fetchAll(db).map(\.id)

      let now = Date().timeIntervalSince1970
      for id in ids {
        try self.deleteRow(id, in: db)
        if shouldTombstone {
          try db.execute(
            sql: "INSERT OR REPLACE INTO clip_tombstone (id, deleted_at) VALUES (?, ?)",
            arguments: [id, now]
          )
        }
      }
      return ids.compactMap(UUID.init(uuidString:))
    }
  }

  public func pendingExport(limit: Int) throws -> [ClipItem] {
    try pool.read { db in
      let rows = try ClipRow
        .filter(Column("exported_at") == nil)
        .order(Column("created_at").asc)
        .limit(limit)
        .fetchAll(db)
      return try self.hydrate(rows, in: db)
    }
  }

  public func markExported(ids: [UUID], at date: Date = Date()) throws {
    guard !ids.isEmpty else { return }
    try pool.write { db in
      let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
      try db.execute(
        sql: "UPDATE clip SET exported_at = ? WHERE id IN (\(placeholders))",
        arguments: StatementArguments([date.timeIntervalSince1970] + ids.map(\.uuidString))
      )
    }
  }

  public func prune(policy: RetentionPolicy, now: Date = Date()) throws -> [UUID] {
    try pool.write { db in
      var victims: Set<String> = []
      // Locked and pinned/filed items are protected, and each has its own
      // switch because locked is a strictly stronger promise.
      var guardClause = ""
      if policy.preservesLocked { guardClause += " AND locked = 0" }
      if policy.preservesPinned { guardClause += " AND pinned = 0 AND collection IS NULL" }
      let binaryKinds = ClipKind.allCases.filter(\.isBinary).map(\.rawValue)

      // Binary payloads only earn their bytes inside the fidelity window.
      if policy.fullFidelityWindow.isFinite {
        let cutoff = now.addingTimeInterval(-policy.fullFidelityWindow).timeIntervalSince1970
        let placeholders = Array(repeating: "?", count: binaryKinds.count).joined(separator: ",")
        victims.formUnion(try String.fetchAll(
          db,
          sql: """
            SELECT id FROM clip
            WHERE created_at < ? AND kind IN (\(placeholders)) \(guardClause)
            """,
          arguments: StatementArguments([cutoff] + binaryKinds)
        ))
      }

      // Textual rows go last and only when a tail window is configured.
      if let window = policy.textTailWindow, window.isFinite {
        let cutoff = now.addingTimeInterval(-window).timeIntervalSince1970
        let placeholders = Array(repeating: "?", count: binaryKinds.count).joined(separator: ",")
        var arguments: [DatabaseValueConvertible?] = [cutoff]
        arguments += binaryKinds
        victims.formUnion(try String.fetchAll(
          db,
          sql: """
            SELECT id FROM clip
            WHERE created_at < ? AND kind NOT IN (\(placeholders)) \(guardClause)
            """,
          arguments: StatementArguments(arguments)
        ))
      }

      // Hard ceiling, applied last.
      if let maximum = policy.maximumItems, maximum > 0 {
        victims.formUnion(try String.fetchAll(
          db,
          sql: """
            SELECT id FROM clip
            WHERE rowid_pk NOT IN (
              SELECT rowid_pk FROM clip
              ORDER BY locked DESC, pinned DESC, created_at DESC LIMIT ?
            )
            \(guardClause)
            """,
          arguments: [maximum]
        ))
      }

      for id in victims { try self.deleteRow(id, in: db) }
      return victims.compactMap(UUID.init(uuidString:))
    }
  }

  public func count() throws -> Int {
    try pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip") ?? 0 }
  }

  public func byteSize() throws -> Int64 {
    try pool.read { db in
      var total: Int64 = 0
      for table in ["clip", "clip_content", "clip_fts"] {
        total += try Int64.fetchOne(
          db,
          sql: "SELECT COALESCE(SUM(LENGTH(CAST(\(table) AS BLOB))), 0) FROM \(table)"
        ) ?? 0
      }
      return total
    }
  }

  private func deleteRow(_ id: String, in db: Database) throws {
    try db.execute(
      sql: "DELETE FROM clip_fts WHERE clip_rowid = (SELECT rowid_pk FROM clip WHERE id = ?)",
      arguments: [id]
    )
    try db.execute(sql: "DELETE FROM clip_content WHERE clip_id = ?", arguments: [id])
    try db.execute(sql: "DELETE FROM clip WHERE id = ?", arguments: [id])
  }
}