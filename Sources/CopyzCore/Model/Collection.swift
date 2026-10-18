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

/// Stable identity for this installation, published so other replicas can tell
/// who has seen what.
///
/// Tombstone collection cannot use a wall-clock TTL: a replica that is offline
/// longer than the TTL would resurrect a deleted clip when it returns. A
/// tombstone may only be collected once every known replica has acknowledged
/// observing the deletion, which requires knowing who exists.
public struct DeviceIdentity: Sendable, Equatable, Codable {
  public var id: UUID
  /// ISO 8601, so a human reading the sidecar can tell when a device was last
  /// active.
  public var lastSeenAt: Date

  public init(id: UUID = UUID(), lastSeenAt: Date = Date()) {
    self.id = id
    self.lastSeenAt = lastSeenAt
  }
}

/// One replica's acknowledgement progress.
///
/// `observedTombstones` is the high-water mark of tombstones this device has
/// seen in the shared sidecar. GC may only collect a tombstone once every known
/// device's mark has passed it.
public struct DeviceWatermark: Sendable, Equatable, Codable {
  public var deviceID: UUID
  /// Logical timestamp of the newest deletion this device has observed.
  public var observedDeletes: Date
  public var updatedAt: Date

  public init(deviceID: UUID, observedDeletes: Date, updatedAt: Date = Date()) {
    self.deviceID = deviceID
    self.observedDeletes = observedDeletes
    self.updatedAt = updatedAt
  }
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
  /// Deletions, keyed by clip id and timestamped so the newest wins on merge.
  public var tombstoneDates: [UUID: Date] = [:]
  /// This installation, so peers can include it in acknowledgement tracking.
  public var identity: DeviceIdentity?
  /// One entry per replica that has reported progress.
  public var watermarks: [UUID: DeviceWatermark] = [:]

  public init() {}

  /// Bumped whenever garbage collection runs.
  ///
  /// A replica whose recorded epoch is older than the current one has missed a
  /// collection round and therefore cannot be trusted to still hold every
  /// deletion — its local-only items are "needs review" rather than re-pushed.
  public var epoch: Int = 1
  /// The epoch each device last saw, so a returning replica can detect it fell
  /// behind.
  public var deviceEpochs: [UUID: Int] = [:]

  /// This installation's identity, created on first use.
  ///
  /// A mutating accessor on a value type, so it lives on `CollectionStore`
  /// rather than here; this returns the recorded id if one exists.
  public var recordedDeviceID: UUID? { identity?.id }

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
      let decoded = try? Self.decoder.decode(VaultSidecar.self, from: data)
    {
      self.sidecar = decoded
    } else {
      self.sidecar = VaultSidecar()
    }
  }

  /// Where the sidecar is written, if it has a location.
  public var sidecarURL: URL? { fileURL }

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
    var record =
      sidecar.pins[clipID]
      ?? PinRecord(clipID: clipID, pinned: pinned)
    record.pinned = pinned
    record.updatedAt = Date()
    sidecar.pins[clipID] = record
  }

  /// Files a clip into a collection. Passing nil un-files it.
  public func setCollection(_ collectionID: UUID?, clipID: UUID) {
    var record =
      sidecar.pins[clipID]
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
    for (id, date) in incoming.tombstoneDates {
      tombstone(id, at: date)
    }
    // Adopt peers' watermarks and epochs so collection knows who has seen what.
    for (device, watermark) in incoming.watermarks where device != sidecar.recordedDeviceID {
      if let existing = sidecar.watermarks[device],
        existing.updatedAt > watermark.updatedAt
      {
        continue
      }
      sidecar.watermarks[device] = watermark
    }
    for (device, epoch) in incoming.deviceEpochs {
      sidecar.deviceEpochs[device] = max(sidecar.deviceEpochs[device] ?? 0, epoch)
    }
    sidecar.epoch = max(sidecar.epoch, incoming.epoch)
  }

  // MARK: - Tombstones

  /// Ids deleted on another machine.
  ///
  /// The vault is never rewritten, so a delete has to travel as metadata or
  /// the note still sitting in the synced folder would be re-imported forever.
  /// Timestamped so the newest delete always wins, matching the pin merge.
  /// This installation's stable identity, created on first use and persisted so
  /// peers can include it in acknowledgement tracking.
  public var deviceID: UUID {
    if let recorded = sidecar.recordedDeviceID { return recorded }
    let created = DeviceIdentity()
    sidecar.identity = created
    return created.id
  }

  public func tombstone(_ clipID: UUID, at date: Date = Date()) {
    if let existing = sidecar.tombstoneDates[clipID], existing > date { return }
    sidecar.tombstoneDates[clipID] = date
  }

  public func isTombstoned(_ clipID: UUID) -> Bool {
    sidecar.tombstoneDates[clipID] != nil
  }

  public var tombstones: Set<UUID> { Set(sidecar.tombstoneDates.keys) }

  // MARK: - Acknowledgement and safe GC

  /// Publishes this device and records that it has seen every tombstone
  /// currently in the sidecar.
  ///
  /// Called on launch and after import. This is what makes tombstone
  /// collection safe: a tombstone is only eligible once *every* known device has
  /// acknowledged passing it.
  public func acknowledgeDeletions() {
    let me = deviceID
    sidecar.identity?.lastSeenAt = Date()
    let newest = sidecar.tombstoneDates.values.max() ?? .distantPast
    let existing = sidecar.watermarks[me]
    sidecar.watermarks[me] = DeviceWatermark(
      deviceID: me,
      observedDeletes: max(existing?.observedDeletes ?? .distantPast, newest),
      updatedAt: Date()
    )
    sidecar.deviceEpochs[me] = sidecar.epoch
  }

  /// Devices other than this one.
  public var knownDevices: Set<UUID> {
    Set(sidecar.watermarks.keys).union(sidecar.deviceEpochs.keys).subtracting([deviceID])
  }

  /// Whether `clipID`'s tombstone may be collected.
  ///
  /// Requires every known replica to have acknowledged a deletion at least as
  /// new as this one. A device that has never reported is treated as blocking,
  /// which is the safe direction: an over-long tombstone is harmless, a
  /// prematurely-collected one resurrects deleted data.
  public func canCollect(_ clipID: UUID, now: Date = Date()) -> Bool {
    guard let deletedAt = sidecar.tombstoneDates[clipID] else { return false }

    let silent = sidecar.retireDevices(silentSince: now, excluding: deviceID)
    for device in knownDevices {
      // A device retired as stale no longer blocks collection, but the epoch
      // bump means it will not silently re-push old items when it returns.
      if silent.contains(device) { continue }
      guard let watermark = sidecar.watermarks[device] else { return false }
      guard watermark.observedDeletes >= deletedAt else { return false }
    }
    return true
  }

  /// Collects tombstones every replica has acknowledged observing.
  ///
  /// Replaces the previous age-based prune, which was unsound: a replica
  /// offline longer than the TTL would resurrect a deleted clip on return.
  /// @discardableResult so tests can assert how many were collected.
  @discardableResult
  public func collectAcknowledgedTombstones(now: Date = Date()) -> Int {
    let before = sidecar.tombstoneDates.count
    sidecar.tombstoneDates = sidecar.tombstoneDates.filter { !canCollect($0.key, now: now) }
    let removed = before - sidecar.tombstoneDates.count
    // Any collection round invalidates earlier acknowledgements.
    if removed > 0 {
      sidecar.epoch += 1
      sidecar.deviceEpochs[deviceID] = sidecar.epoch
    }
    return removed
  }

  /// Drops tombstones older than `date`.
  ///
  /// Retained for the single-machine case, where there are no peers to wait for
  /// and an age bound is unambiguous. Never use it when peers exist.
  @discardableResult
  public func pruneTombstones(olderThan date: Date) -> Int {
    let before = sidecar.tombstoneDates.count
    sidecar.tombstoneDates = sidecar.tombstoneDates.filter { $0.value > date }
    return before - sidecar.tombstoneDates.count
  }

  /// Whether this device has fallen behind a collection round.
  public func hasFallenBehind() -> Bool {
    let recorded = sidecar.deviceEpochs[deviceID] ?? sidecar.epoch
    return recorded < sidecar.epoch
  }

  public var allPins: [UUID: PinRecord] { sidecar.pins }
}

extension VaultSidecar {
  /// Devices with no recent activity, retired so they stop blocking collection.
  ///
  /// A retired device does not silently return with stale data: the epoch bump
  /// on collection means it is told it fell behind, and its local-only items are
  /// treated as needing review rather than re-pushed.
  func retireDevices(silentSince now: Date, excluding me: UUID) -> Set<UUID> {
    let cutoff = now.addingTimeInterval(-Self.retirementInterval)
    let stale = watermarks.values
      .filter { $0.updatedAt < cutoff && $0.deviceID != me }
      .map(\.deviceID)
    return Set(stale)
  }

  /// How long a replica may be silent before it stops blocking tombstone
  /// collection. Six weeks covers a laptop that is simply closed.
  static let retirementInterval: TimeInterval = 60 * 24 * 3600
}
