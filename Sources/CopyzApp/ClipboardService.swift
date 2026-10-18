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
      vaultError = nil
    } catch {
      vaultError = error.localizedDescription
      log.error("vault prepare failed: \(error.localizedDescription, privacy: .public)")
    }

    items = (try? store.recent(limit: 200, includeUnpinnedOnly: false)) ?? []
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

  public func search(_ query: String) {
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
      items = (try? store.recent(limit: 200, includeUnpinnedOnly: false)) ?? []
      return
    }
    do {
      items = try store.search(query, limit: 200)
    } catch {
      log.error("search failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  public func reload() {
    items = (try? store.recent(limit: 200, includeUnpinnedOnly: false)) ?? []
  }

  // MARK: - Actions

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
    let next = !item.pinned
    try? store.setPinned(next, id: item.id)
    if let index = items.firstIndex(where: { $0.id == item.id }) {
      items[index].pinned = next
    }
    // Pin state lives in the note frontmatter, so re-export it.
    Task {
      if let updated = try? store.item(id: item.id) {
        await vault.writeNow(updated)
      }
    }
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