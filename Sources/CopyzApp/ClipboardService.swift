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

    // Collections, pin state, and tombstones live in a small sidecar inside
    // the vault, so they sync through whatever folder the user picked. Built
    // before `VaultStore` because import consults it for tombstones.
    let sidecarURL = settings.vaultURL.appending(path: ".copyz/sidecar.json")
    self.sidecarURL = sidecarURL
    let collectionStore = CollectionStore(sidecarURL: sidecarURL)
    self.collections = collectionStore

    self.vault = VaultStore(
      store: store,
      writer: VaultWriter(rootURL: settings.vaultURL),
      collections: collectionStore
    )
    self.monitor = PasteboardMonitor(
      configuration: .init(pollInterval: settings.pollInterval),
      rules: settings.rules
    )

    monitor.onEvent = { [weak self] event in
      self?.handle(event)
    }
  }

  /// Test seam: every path supplied explicitly.
  ///
  /// The default initialiser reaches into Application Support, which makes the
  /// service impossible to exercise without trampling the user's real history.
  /// The monitoring half is deliberately left unwired here — tests drive
  /// `store` directly rather than going through a live pasteboard.
  init(
    settings: Settings,
    store: SQLiteClipStore,
    vault: VaultStore,
    collections: CollectionStore,
    sidecarURL: URL
  ) {
    self.settings = settings
    self.store = store
    self.vault = vault
    self.collections = collections
    self.sidecarURL = sidecarURL
    self.monitor = PasteboardMonitor(
      configuration: .init(pollInterval: settings.pollInterval),
      rules: settings.rules
    )
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
    // Wires up the Settings maintenance buttons. Must happen after the service
    // is otherwise initialised, or a queued command could hit a half-built
    // vault.
    observeMaintenanceCommands()
    monitor.start()
    scheduleMaintenance()
  }

  public func stop() async {
    monitor.stop()
    removeMaintenanceObservers()
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
    // Record the deletion in the sidecar as well, so it survives on the other
    // machines the vault syncs to. The note itself is left alone: import is
    // read-only and the user's synced copy is not ours to rewrite.
    Task {
      await collections.tombstone(item.id)
      try? await collections.save()
    }
    items.removeAll { $0.id == item.id }
  }

  /// Stronger than pinning: survives a clear-history.
  public func toggleLock(_ item: ClipItem) {
    let next = !item.locked
    try? store.setLocked(next, id: item.id)
    if let index = items.firstIndex(where: { $0.id == item.id }) {
      items[index].locked = next
    }
    Task {
      if let updated = try? store.item(id: item.id) {
        await vault.writeNow(updated)
      }
    }
  }

  /// Deletes history.
  ///
  /// `async` on purpose: the sidecar write must be awaited, not fired into a
  /// detached `Task`. Otherwise quitting the app immediately after clearing
  /// leaves tombstones unwritten, and every other machine's vault re-imports
  /// exactly what the user just deleted.
  public func clearAll(includingPinned: Bool) async {
    // A user clearing history is a deliberate delete, so it tombstones: without
    // that, every other machine's vault would re-import what was just cleared.
    let removed = (try? store.deleteAll(includingPinned: includingPinned, tombstone: true)) ?? []
    for id in removed {
      await collections.tombstone(id)
    }
    // Publish our own acknowledgement too, or the first collection round would
    // be blocked by our own watermark.
    await collections.acknowledgeDeletions()
    await persistCollections()
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
      _ = try store.deleteAll(includingPinned: true, tombstone: false)
      _ = try await vault.rebuildIndex()
      reload()
    } catch {
      log.error("rebuild failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Writes everything pending to the vault. Returns how many notes were written,
  /// which is zero when the vault is unreachable.
  @discardableResult
  public func flushVault() async -> Int {
    await vault.flushNow()
  }

  /// Reclaims space and merges the search index, regardless of how much is at
  /// stake. The automatic pass is threshold-based because `VACUUM` needs an
  /// exclusive lock; an explicit request from the user is unconditional.
  public func compactDatabase() {
    do {
      let reclaimed = try store.compact(force: true)
      log.info("manual compaction reclaimed \(reclaimed) pages")
      reload()
    } catch {
      log.error("compaction failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Observes the maintenance commands posted by the Settings buttons.
  ///
  /// Tokens are retained and the observers removed on `stop()`. Registering
  /// without keeping them means a second `start()` silently doubles every
  /// handler, so one flush becomes two and one rebuild becomes two — the kind of
  /// bug that only shows up after a restart and never reproduces in isolation.
  ///
  /// Called once at startup. The buttons used to post notifications that nothing
  /// was listening for, so they silently did nothing; a `NotificationCenter`
  /// round trip has no compiler checking to catch that.
  public func observeMaintenanceCommands() {
    // Idempotent: a second `start()` must not leave the first registration in
    // place alongside the new one.
    removeMaintenanceObservers()
    let center = NotificationCenter.default
    maintenanceObservers = [
      .copyzFlushVault, .copyzRebuildVault, .copyzCompact,
    ].map { name in
      center.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in
        guard let self else { return }
        Task { @MainActor in
          switch name {
          case .copyzFlushVault: await self.flushVault()
          case .copyzRebuildVault: await self.rebuildFromVault()
          default: self.compactDatabase()
          }
        }
      }
    }
  }

  private var maintenanceObservers: [NSObjectProtocol] = []

  private func removeMaintenanceObservers() {
    for observer in maintenanceObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    maintenanceObservers = []
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
      // Deletions only become collectable once every replica has seen them.
      // Running this here rather than at delete time means a peer that was
      // offline still blocks collection when it matters.
      await collections.acknowledgeDeletions()
      _ = await collections.collectAcknowledgedTombstones()
      await persistCollections()
      // Reclaims the pages freed by pruning and merges FTS segments. Skipped
      // automatically unless enough is at stake to justify the exclusive lock.
      try store.compactIfNeeded()
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