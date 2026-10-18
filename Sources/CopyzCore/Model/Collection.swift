import Foundation

/// A user-defined grouping, the clipboard equivalent of Paste's pinboards.
///
/// Collections are metadata only — they never move or copy history rows, which
/// is what makes them cheap to keep in sync across machines through the vault.
public struct Collection: Sendable, Identifiable, Equatable, Codable {
  public var id: UUID
  public var name: String
  /// SF Symbol name shown in the sidebar.
  public var symbolName: String
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    symbolName: String = "folder",
    createdAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.symbolName = symbolName
    self.createdAt = createdAt
  }

  /// Filename-safe form, so a collection name with a slash cannot escape its
  /// directory in the vault.
  public var slug: String {
    var out = ""
    var previousWasHyphen = false
    for character in name.lowercased() {
      if character.isLetter || character.isNumber {
        out.append(character)
        previousWasHyphen = false
      } else if !previousWasHyphen, !out.isEmpty {
        // Collapse every run of separators into one hyphen, so "Work / Stuff"
        // does not become "work--stuff".
        out.append("-")
        previousWasHyphen = true
      }
    }
    while out.hasSuffix("-") { out.removeLast() }
    return out.isEmpty ? "collection" : out
  }

  public static let defaultSymbolOptions = [
    "folder", "tray", "archivebox", "bookmark", "tag",
    "star", "heart", "flag", "bolt", "key",
    "doc.text", "globe", "link", "number", "calendar",
  ]
}

/// Pin state, kept separate from the clip body.
///
/// Pinned flags are the one piece of clip metadata that changes after the fact,
/// and two machines editing the same clip would otherwise fight over it. Keeping
/// them in one small sidecar file means the conflict window is a few hundred
/// bytes rather than whole notes.
public struct PinRecord: Sendable, Equatable, Codable {
  public var clipID: UUID
  public var pinned: Bool
  public var collectionID: UUID?
  /// Last writer wins.
  public var updatedAt: Date

  public init(clipID: UUID, pinned: Bool, collectionID: UUID? = nil, updatedAt: Date = Date()) {
    self.clipID = clipID
    self.pinned = pinned
    self.collectionID = collectionID
    self.updatedAt = updatedAt
  }
}

/// Sidecar state file, `.copyz/pins.json` in the vault.
public struct VaultSidecar: Sendable, Equatable, Codable {
  public var schema: Int = 1
  public var collections: [Collection] = []
  public var pins: [UUID: PinRecord] = [:]

  public init() {}

  public mutating func apply(_ record: PinRecord) {
    // Last writer wins, so an older sync from another machine cannot undo a
    // newer change made here.
    if let existing = pins[record.clipID], existing.updatedAt > record.updatedAt {
      return
    }
    pins[record.clipID] = record
  }
}

/// Stores collections and pin state.
public actor CollectionStore {
  private var sidecar: VaultSidecar
  private let fileURL: URL?
  private let fileManager: FileManager

  /// Both strategies must match. A mismatch here silently decodes to nothing,
  /// which looks exactly like "the user lost their pins".
  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  public init(sidecarURL: URL?, fileManager: FileManager = .default) {
    self.fileURL = sidecarURL
    self.fileManager = fileManager
    if let sidecarURL, let data = try? Data(contentsOf: sidecarURL),
       let decoded = try? Self.decoder.decode(VaultSidecar.self, from: data) {
      self.sidecar = decoded
    } else {
      self.sidecar = VaultSidecar()
    }
  }

  // MARK: - Collections

  public var collections: [Collection] {
    sidecar.collections.sorted { $0.createdAt < $1.createdAt }
  }

  public func collection(id: UUID) -> Collection? {
    sidecar.collections.first { $0.id == id }
  }

  /// Adds or updates a collection. An existing collection with the same name is
  /// reused rather than duplicated, since that is almost always what the user
  /// meant.
  @discardableResult
  public func upsert(_ collection: Collection) -> Collection {
    if let index = sidecar.collections.firstIndex(where: {
      $0.id == collection.id || $0.name.caseInsensitiveCompare(collection.name) == .orderedSame
    }) {
      var updated = collection
      // Preserve the original identity and creation date when renaming.
      updated.id = sidecar.collections[index].id
      updated.createdAt = sidecar.collections[index].createdAt
      sidecar.collections[index] = updated
      return updated
    }
    sidecar.collections.append(collection)
    return collection
  }

  @discardableResult
  public func rename(_ id: UUID, to name: String) -> Collection? {
    guard let index = sidecar.collections.firstIndex(where: { $0.id == id }) else {
      return nil
    }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    sidecar.collections[index].name = trimmed
    return sidecar.collections[index]
  }

  /// Deletes a collection. Items in it are kept and simply become unfiled.
  public func deleteCollection(_ id: UUID) {
    sidecar.collections.removeAll { $0.id == id }
    for (key, var record) in sidecar.pins {
      if record.collectionID == id {
        record.collectionID = nil
        sidecar.pins[key] = record
      }
    }
  }

  // MARK: - Pins and filing

  public func pinRecord(for clipID: UUID) -> PinRecord? {
    sidecar.pins[clipID]
  }

  public func isPinned(_ clipID: UUID) -> Bool {
    sidecar.pins[clipID]?.pinned ?? false
  }

  public func collectionID(for clipID: UUID) -> UUID? {
    sidecar.pins[clipID]?.collectionID
  }

  public func setPinned(_ pinned: Bool, clipID: UUID) {
    var record = sidecar.pins[clipID]
      ?? PinRecord(clipID: clipID, pinned: pinned)
    record.pinned = pinned
    record.updatedAt = Date()
    sidecar.pins[clipID] = record
  }

  /// Files a clip into a collection. Passing nil un-files it.
  public func setCollection(_ collectionID: UUID?, clipID: UUID) {
    var record = sidecar.pins[clipID]
      ?? PinRecord(clipID: clipID, pinned: false)
    record.collectionID = collectionID
    record.updatedAt = Date()
    sidecar.pins[clipID] = record
  }

  public func togglePinned(_ clipID: UUID) -> Bool {
    let next = !isPinned(clipID)
    setPinned(next, clipID: clipID)
    return next
  }

  /// Ids that must never be pruned.
  public func protectedClipIDs() -> Set<UUID> {
    Set(sidecar.pins.values.filter { $0.pinned || $0.collectionID != nil }.map(\.clipID))
  }

  // MARK: - Persistence

  /// Writes the sidecar atomically, so a sync client never observes a
  /// half-written file.
  public func save() throws {
    guard let fileURL else { return }
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Self.encoder.encode(sidecar).write(to: fileURL, options: [.atomic])
  }

  /// Merges a sidecar read from disk, honouring per-record timestamps.
  public func merge(_ incoming: VaultSidecar) {
    for record in incoming.pins.values {
      sidecar.apply(record)
    }
    for collection in incoming.collections {
      _ = upsert(collection)
    }
  }

  public var allPins: [UUID: PinRecord] { sidecar.pins }
}