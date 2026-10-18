import AppKit
import CopyzCore
import CopyzPaste
import Foundation
import Observation
import os

/// Wires the pasteboard, the store, and the vault together.
///
/// This is the single place that knows the ordering of a capture: record to
/// SQLite first (so nothing is lost if the vault is unreachable), then schedule
/// the vault flush, then prune.
@MainActor
@Observable
public final class ClipboardService {
  private let store: SQLiteClipStore
  private let vault: VaultStore
  private let monitor: PasteboardMonitor
  public let collections: CollectionStore
  private let sidecarURL: URL
  private let log = Logger(subsystem: "app.copyz", category: "service")

  /// Most recent items, newest first.
  public private(set) var items: [ClipItem] = []
  /// Why the last copy was not recorded, if it was not.
  public private(set) var lastRejection: CaptureRules.Rejection?
  public private(set) var vaultError: String?

  /// The app that was frontmost before our panel opened. Captured at hotkey
  /// time, because by paste time we are the frontmost app.
  public private(set) var pasteTarget: NSRunningApplication?

  public let settings: Settings

  public init(settings: Settings) throws {
    self.settings = settings
    self.store = try SQLiteClipStore.makeDefault()
    self.vault = VaultStore(
      store: store,
      writer: VaultWriter(rootURL: settings.vaultURL)
    )
    self.monitor = PasteboardMonitor(
      configuration: .init(pollInterval: settings.pollInterval),
      rules: settings.rules
    )
    // Collections and pin state live in a small sidecar inside the vault, so
    // they sync through whatever folder the user picked.
    let sidecarURL = settings.vaultURL.appending(path: ".copyz/sidecar.json")
    self.sidecarURL = sidecarURL
    self.collections = CollectionStore(sidecarURL: sidecarURL)

    monitor.onEvent = { [weak self] event in
      self?.handle(event)
    }
  }

  public func start() async {
    monitor.updateConfiguration(.init(pollInterval: settings.pollInterval))

    do {
      try await vault.prepare()
      // Anything captured before the last quit but never flushed goes out now.
      _ = await vault.flushNow()
      _ = await vault.importFromVault()
      // Write the sidecar even when empty, so its location is discoverable.
      await persistCollections()
      vaultError = nil
    } catch {
      vaultError = error.localizedDescription
      log.error("vault prepare failed: \(error.localizedDescription, privacy: .public)")
    }

    await refreshCollectionNames()
    reload()
    monitor.start()
    scheduleMaintenance()
  }

  public func stop() async {
    monitor.stop()
    await vault.flushOnShutdown()
  }

  // MARK: - Capture

  private func handle(_ event: PasteboardMonitor.Event) {
    switch event {
    case .captured(let item):
      lastRejection = nil
      do {
        // SQLite first: the vault may be unmounted, moved, or offline, and
        // losing the clip to a sync hiccup would be far worse than a late write.
        let stored = try store.record(item)
        upsert(stored)
        Task { await vault.scheduleFlush() }
      } catch {
        log.error("record failed: \(error.localizedDescription, privacy: .public)")
      }

    case .rejected(let rejection):
      lastRejection = rejection
    }
  }

  // MARK: - Queries

  /// Current filter on the history list.
  public enum Filter: Hashable, Sendable {
    case all
    case pinned
    case unfiled
    case collection(UUID)
    case kind(ClipKind)
  }

  public private(set) var filter: Filter = .all
  /// Snapshot of collection id → name, so filtering stays synchronous.
  private var collectionNames: [UUID: String] = [:]

  public func setFilter(_ filter: Filter) {
    self.filter = filter
    reload()
  }

  public func search(_ query: String) {
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
      reload()
      return
    }
    do {
      // Search over the whole history, then narrow to the active filter so a
      // query is not silently confined to one collection.
      items = try store.search(query, limit: 500).filter(matches(filter))
    } catch {
      log.error("search failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  public func reload() {
    items = ((try? store.recent(limit: 500, includeUnpinnedOnly: false)) ?? [])
      .filter(matches(filter))
  }

  private func matches(_ filter: Filter) -> (ClipItem) -> Bool {
    { item in
      switch filter {
      case .all: return true
      case .pinned: return item.pinned
      case .unfiled: return item.collection == nil
      case .kind(let kind): return item.kind == kind
      case .collection(let id):
        guard let name = self.collectionNames[id] else { return false }
        return item.collection == name
      }
    }
  }

  // MARK: - Actions

  /// Records transformed text as a new clip.
  ///
  /// The original is left untouched: the usual intent is to keep what was
  /// copied *and* have the converted form available, not to lose one to the other.
  public func copyTextAsNewClip(_ text: String, derivedFrom source: ClipItem?) {
    let item = ClipItem(
      sourceBundleID: source?.sourceBundleID,
      sourceAppName: source?.sourceAppName,
      contents: [ClipContent(
        type: PasteboardType.string.rawValue,
        value: Data(text.utf8)
      )]
    )
    do {
      let stored = try store.record(item)
      upsert(stored)
      Task { await vault.scheduleFlush() }
    } catch {
      log.error("transform record failed: \(error.localizedDescription, privacy: .public)")
    }

    let pasteboard = PasteboardWriter.write(item)
    if pasteboard { monitor.noteOwnWrite() }
  }

  /// Restores `item` to the pasteboard without pasting.
  @discardableResult
  public func copy(_ item: ClipItem, plainTextOnly: Bool = false) -> Bool {
    let wrote = PasteboardEngineBridge.write(item, plainTextOnly: plainTextOnly)
    // Our own write must not be recorded as a fresh capture.
    monitor.noteOwnWrite()
    try? store.markUsed(id: item.id)
    return wrote
  }

  /// Pastes `item` into the app that was frontmost before the panel opened.
  public func paste(_ item: ClipItem, plainTextOnly: Bool = false) {
    let target = pasteTarget
    let result = PasteEngine.paste(
      item: item,
      into: target,
      plainTextOnly: plainTextOnly
    )
    monitor.noteOwnWrite()
    try? store.markUsed(id: item.id)

    if case .failure = result {
      // Accessibility refused. Fall back to copy-only and tell the user,
      // rather than silently doing nothing.
      _ = copy(item, plainTextOnly: plainTextOnly)
    }
  }

  /// Records the paste target. Called from the hotkey handler, before the
  /// panel can take focus.
  public func notePasteTarget(_ app: NSRunningApplication?) {
    pasteTarget = app
  }

  public func togglePin(_ item: ClipItem) {
    Task {
      let next = await collections.togglePinned(item.id)
      try? store.setPinned(next, id: item.id)
      try? await collections.save()
      if let index = items.firstIndex(where: { $0.id == item.id }) {
        items[index].pinned = next
      }
    }
  }

  public func file(_ item: ClipItem, into collectionID: UUID?) {
    Task {
      await collections.setCollection(collectionID, clipID: item.id)
      try? await collections.save()

      // Resolve the name separately: `flatMap` cannot host an async call.
      var name: String?
      if let collectionID, let resolved = await collections.collection(id: collectionID) {
        name = resolved.name
      }
      try? store.setCollection(name, id: item.id)
      if let index = items.firstIndex(where: { $0.id == item.id }) {
        items[index].collection = name
      }
    }
  }

  public func makeCollection(name: String) async -> Collection {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let collection = await collections.upsert(Collection(name: trimmed))
    try? await collections.save()
    await refreshCollectionNames()
    return collection
  }

  public func deleteCollection(_ id: UUID) async {
    await collections.deleteCollection(id)
    try? await collections.save()
    await refreshCollectionNames()
    reload()
  }

  public func renameCollection(_ id: UUID, to name: String) async {
    await collections.rename(id, to: name)
    try? await collections.save()
    await refreshCollectionNames()
  }

  public func allCollections() async -> [Collection] {
    await collections.collections
  }

  private func refreshCollectionNames() async {
    let list = await collections.collections
    collectionNames = Dictionary(
      uniqueKeysWithValues: list.map { ($0.id, $0.name) }
    )
    TaskCache.shared.update(collections: list)
  }

  public func delete(_ item: ClipItem) {
    try? store.delete(id: item.id)
    items.removeAll { $0.id == item.id }
    // The vault note is left alone: import is read-only, and the user's synced
    // copy is not ours to rewrite.
  }

  public func clearAll(includingPinned: Bool) {
    _ = try? store.deleteAll(includingPinned: includingPinned)
    reload()
  }

  public var stats: (count: Int, databaseBytes: Int64) {
    ((try? store.count()) ?? 0, (try? store.byteSize()) ?? 0)
  }

  /// Persists collections and pin state immediately.
  ///
  /// Called after every metadata change: the sidecar is a single small file, and
  /// leaving it unwritten until an unrelated vault flush would mean a crash
  /// silently loses pin and collection changes.
  func persistCollections() async {
    try? await collections.save()
  }

  public func vaultByteSize() async -> Int64 {
    await vault.byteSize()
  }

  /// Reads back what the vault currently holds. Used by the settings pane to
  /// verify the folder is really being written.
  public func vaultNotes() async -> [VaultNote.Decoded] {
    await vault.readAll(limit: 5_000)
  }

  public func rebuildFromVault() async {
    do {
      _ = try store.deleteAll(includingPinned: true)
      _ = try await vault.rebuildIndex()
      reload()
    } catch {
      log.error("rebuild failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  public func flushVault() async {
    await vault.flushNow()
  }

  public func skipNextCopy() {
    monitor.skipNextCopy()
  }

  public func applyRules() {
    monitor.rules = settings.rules
    monitor.updateConfiguration(.init(pollInterval: settings.pollInterval))
  }

  // MARK: - Maintenance

  private func scheduleMaintenance() {
    Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(600))
        guard let self, !Task.isCancelled else { return }
        await self.runMaintenance()
      }
    }
  }

  private func runMaintenance() async {
    do {
      // Retention is what keeps a synced folder from churning thousands of
      // files, so it runs on a timer rather than only at launch.
      _ = try store.prune(policy: settings.retention)
      _ = await vault.flushNow()
      _ = await vault.importFromVault()
      reload()
    } catch {
      log.error("maintenance failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func upsert(_ item: ClipItem) {
    if let index = items.firstIndex(where: { $0.id == item.id }) {
      items[index] = item
    } else {
      items.insert(item, at: 0)
    }
    if items.count > 500 {
      items.removeLast(items.count - 500)
    }
  }
}

/// Small shim so `ClipboardService` does not need AppKit pasteboard plumbing in
/// more than one place.
@MainActor
enum PasteboardEngineBridge {
  @discardableResult
  static func write(_ item: ClipItem, plainTextOnly: Bool = false) -> Bool {
    PasteboardWriter.write(item, to: .general, plainTextOnly: plainTextOnly)
  }
}