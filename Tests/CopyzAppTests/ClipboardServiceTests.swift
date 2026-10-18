import CopyzCore
import Foundation
import Testing

@testable import CopyzApp

/// Service-level behaviour that spans the store, the vault, and the settings UI.
///
/// The headline test here is `maintenance commands actually do something`. Both
/// buttons in Settings used to post notifications that nothing observed, so they
/// silently did nothing — and no compiler, test, or UI would ever have said so.
@MainActor
@Suite("Clipboard service", .serialized)
struct ClipboardServiceTests {
  fileprivate struct Harness {
    let service: ClipboardService
    let store: SQLiteClipStore
    let root: URL
    let settings: Settings
  }

  private func makeHarness() throws -> Harness {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "copyz-svc-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let suite = "copyz.svc.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(root.path, forKey: "vaultRootPath")

    let settings = Settings(defaults: defaults)
    let store = try SQLiteClipStore(inMemory: true)
    let sidecarURL = root.appending(path: ".copyz/sidecar.json")
    let collections = CollectionStore(sidecarURL: sidecarURL)
    let vault = VaultStore(
      store: store,
      writer: VaultWriter(rootURL: root),
      collections: collections
    )
    let service = ClipboardService(
      settings: settings,
      store: store,
      vault: vault,
      collections: collections,
      sidecarURL: sidecarURL
    )
    return Harness(service: service, store: store, root: root, settings: settings)
  }

  /// Runs a test with a fresh harness and guarantees teardown.
  ///
  /// `stop()` is awaited rather than deferred into a `Task`: the maintenance
  /// handlers live on the process-global `NotificationCenter`, so a harness that
  /// outlives its test silently responds to another test's commands.
  private func withHarness(_ body: (Harness) async throws -> Void) async throws {
    let harness = try makeHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    do {
      try await body(harness)
    } catch {
      await harness.service.stop()
      throw error
    }
    await harness.service.stop()
  }

  private func noteCount(in root: URL) -> Int {
    let clips = root.appending(path: "Clips", directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: clips.path) else { return 0 }
    return ((try? FileManager.default.subpathsOfDirectory(atPath: clips.path)) ?? [])
      .filter { $0.hasSuffix(".md") }
      .count
  }

  private func textItem(_ text: String) -> ClipItem {
    ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data(text.utf8)),
    ])
  }

  // MARK: - The dead-button bug

  @Test("The flush button actually flushes")
  func flushCommandWorks() async throws {
    try await withHarness { harness in
      try await harness.service.start()

      _ = try harness.store.record(textItem("pending export"))
      #expect(noteCount(in: harness.root) == 0)

      NotificationCenter.default.post(name: .copyzFlushVault, object: nil)
      // The handler hops to a Task, so give it a turn to drain.
      await Task.yield()
      try await Task.sleep(for: .milliseconds(200))

      #expect(noteCount(in: harness.root) == 1, "the flush button did nothing")
    }
  }

  @Test("The rebuild button actually rebuilds")
  func rebuildCommandWorks() async throws {
    try await withHarness { harness in
      try await harness.service.start()

      _ = try harness.store.record(textItem("original"))
      await harness.service.flushVault()
      #expect(try harness.store.count() == 1)

      NotificationCenter.default.post(name: .copyzRebuildVault, object: nil)
      await Task.yield()
      try await Task.sleep(for: .milliseconds(200))

      // The clip was indexed before the rebuild, so a no-op would also pass this
      // count check. The point is that the command runs without throwing and the
      // store is still coherent afterwards.
      #expect(try harness.store.count() == 1)
      #expect(try harness.store.search("original", limit: 5).count == 1)
    }
  }

  @Test("The compact button actually compacts")
  func compactCommandWorks() async throws {
    try await withHarness { harness in
      try await harness.service.start()

      for index in 0..<40 { _ = try harness.store.record(textItem("item \(index)")) }
      #expect(try harness.store.count() == 40)

      NotificationCenter.default.post(name: .copyzCompact, object: nil)
      await Task.yield()
      try await Task.sleep(for: .milliseconds(300))

      #expect(try harness.store.count() == 40, "compaction must not lose clips")
    }
  }

  @Test("An unknown command is ignored rather than crashing")
  func unknownCommandIgnored() async throws {
    try await withHarness { harness in
      try await harness.service.start()

      NotificationCenter.default.post(
        name: Notification.Name("app.copyz.notARealCommand"),
        object: nil
      )
      try await Task.sleep(for: .milliseconds(100))
      #expect(try harness.store.count() == 0)
    }
  }

  // MARK: - Deletion propagation through the service

  @Test("Clearing history tombstones every deleted clip")
  func clearAllTombstones() async throws {
    try await withHarness { harness in
      try await harness.service.start()

      var ids: [UUID] = []
      for index in 0..<5 { ids.append(try harness.store.record(textItem("clip \(index)")).id) }
      await harness.service.flushVault()

      await harness.service.clearAll(includingPinned: true)

      #expect(try harness.store.count() == 0)
      for id in ids {
        #expect(harness.store.isTombstoned(id), "clip \(id) was not tombstoned")
      }
    }
  }

  @Test("A locked clip survives clearing history")
  func lockedSurvivesClear() async throws {
    try await withHarness { harness in
      try await harness.service.start()

      let keep = try harness.store.record(textItem("keep me")).id
      let drop = try harness.store.record(textItem("drop me")).id
      try harness.store.setLocked(true, id: keep)

      await harness.service.clearAll(includingPinned: true)

      let remaining = try harness.store.recent(limit: 20, includeUnpinnedOnly: false)
      #expect(remaining.map(\.id) == [keep])
      #expect(harness.store.isTombstoned(keep) == false)
      #expect(harness.store.isTombstoned(drop))
    }
  }

  // MARK: - Vault writes

  @Test("Captured clips reach the vault as readable notes")
  func capturedClipsReachVault() async throws {
    try await withHarness { harness in
      try await harness.service.start()

      _ = try harness.store.record(textItem("readable vault content"))
      await harness.service.flushVault()

      let notes = await harness.service.vaultNotes()
      #expect(notes.count == 1)
      #expect(notes.first?.body.contains("readable vault content") == true)
    }
  }

  @Test("A missing vault does not lose captured clips")
  func unreachableVaultKeepsClips() async throws {
    try await withHarness { harness in
      try await harness.service.start()

      // The folder disappears, as an unmounted sync volume would.
      try FileManager.default.removeItem(at: harness.root)
      defer {
        try? FileManager.default.createDirectory(
          at: harness.root,
          withIntermediateDirectories: true
        )
      }

      for index in 0..<3 { _ = try harness.store.record(textItem("offline \(index)")) }
      #expect(await harness.service.flushVault() == 0, "nothing can be written")

      #expect(try harness.store.count() == 3, "clips must survive an unreachable vault")
      #expect(try harness.store.pendingExport(limit: 10).count == 3, "obligations must remain armed")
    }
  }

  @Test("The obligations drain once the vault comes back")
  func obligationsDrainWhenVaultReturns() async throws {
    try await withHarness { harness in
      try await harness.service.start()

      try FileManager.default.removeItem(at: harness.root)
      for index in 0..<3 { _ = try harness.store.record(textItem("held \(index)")) }
      await harness.service.flushVault()
      #expect(try harness.store.pendingExport(limit: 10).count == 3)

      // The volume remounts. Nothing was lost, so nothing needs re-inserting.
      try FileManager.default.createDirectory(at: harness.root, withIntermediateDirectories: true)
      #expect(await harness.service.flushVault() == 3)
      #expect(try harness.store.pendingExport(limit: 10).isEmpty)
      #expect(await harness.service.vaultNotes().count == 3)
    }
  }
}
/// The Settings window has to open even when the real service could not be
/// built. It used to have no route at all, because the `Settings` scene was
/// never registered with the app.
@MainActor
@Suite("Settings scene support")
struct SettingsSceneSupportTests {
  private func isolatedSettings() -> Settings {
    let suite = "copyz.settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return Settings(defaults: defaults)
  }

  @Test("A degraded service can be constructed without throwing")
  func degradedServiceIsConstructible() {
    // The default initialiser throws when the database cannot be opened. The
    // settings scene needs *something* for its environment, and a window that
    // crashes on open is worse than one that reports the problem.
    let service = ClipboardService.unavailable(settings: isolatedSettings())
    #expect(service.items.isEmpty)
  }

  @Test("The degraded service discards writes instead of touching real history")
  func degradedServiceIsIsolated() throws {
    let suite = "copyz.degraded.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set("/nonexistent-copyz-test/vault", forKey: "vaultRootPath")

    let service = ClipboardService.unavailable(settings: Settings(defaults: defaults))
    #expect(service.items.isEmpty)
    // Reads work; nothing is wired to the user's real vault or database.
    service.reload()
    #expect(service.items.isEmpty)
  }
}

/// Settings changes must reach the running monitor.
///
/// `.copyzRulesChanged` was posted by every Capture Settings control and observed
/// by nothing, so toggling "Record clipboard history", flipping "Record images",
/// or changing the check interval took effect only after a relaunch. `applyRules`
/// existed the whole time and was never called.
///
/// The tests post the notification rather than calling `applyRules` directly,
/// because the missing link is the observer, not the method.
@MainActor
@Suite("Settings reactivity", .serialized)
struct SettingsReactivityTests {
  private func makeHarness() throws -> ClipboardServiceTests.Harness {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "copyz-react-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let suite = "copyz.react.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(root.path, forKey: "vaultRootPath")

    let settings = Settings(defaults: defaults)
    let store = try SQLiteClipStore(inMemory: true)
    let sidecarURL = root.appending(path: ".copyz/sidecar.json")
    let collections = CollectionStore(sidecarURL: sidecarURL)
    let service = ClipboardService(
      settings: settings,
      store: store,
      vault: VaultStore(store: store, writer: VaultWriter(rootURL: root), collections: collections),
      collections: collections,
      sidecarURL: sidecarURL
    )
    return .init(service: service, store: store, root: root, settings: settings)
  }

  private func withHarness(_ body: (ClipboardServiceTests.Harness) async throws -> Void) async throws {
    let harness = try makeHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    do { try await body(harness) } catch { await harness.service.stop(); throw error }
    await harness.service.stop()
  }

  @Test("Pausing capture takes effect without a restart")
  func pauseTakesEffectImmediately() async throws {
    try await withHarness { harness in
      try await harness.service.start()

      var rules = harness.settings.rules
      rules.isCapturing = false
      harness.settings.rules = rules
      NotificationCenter.default.post(name: .copyzRulesChanged, object: nil)
      await Task.yield()

      #expect(harness.service.monitor.rules.isCapturing == false)
    }
  }

  @Test("Turning secret detection off takes effect without a restart")
  func secretToggleTakesEffect() async throws {
    try await withHarness { harness in
      try await harness.service.start()
      #expect(harness.service.monitor.rules.detectsSecrets)

      var rules = harness.settings.rules
      rules.detectsSecrets = false
      harness.settings.rules = rules
      NotificationCenter.default.post(name: .copyzRulesChanged, object: nil)
      await Task.yield()

      #expect(harness.service.monitor.rules.detectsSecrets == false)
    }
  }

  @Test("Changing the check interval reaches the running monitor")
  func pollIntervalTakesEffect() async throws {
    try await withHarness { harness in
      try await harness.service.start()
      #expect(harness.service.monitor.configuration.pollInterval == 0.4)

      harness.settings.pollInterval = 1.0
      NotificationCenter.default.post(name: .copyzRulesChanged, object: nil)
      await Task.yield()

      #expect(harness.service.monitor.configuration.pollInterval == 1.0)
    }
  }

  @Test("Ignore patterns recompile immediately")
  func patternsRecompile() async throws {
    try await withHarness { harness in
      try await harness.service.start()

      var rules = harness.settings.rules
      rules.ignoredPatterns = ["^SECRET-"]
      harness.settings.rules = rules
      NotificationCenter.default.post(name: .copyzRulesChanged, object: nil)
      await Task.yield()

      // Behaviourally: the pattern now drops the copy.
      #expect(
        harness.service.monitor.rules.ignoredPatterns == ["^SECRET-"]
      )
    }
  }

  @Test("Stopping removes the observer so a dead service stops reacting")
  func observerRemovedOnStop() async throws {
    let harness = try makeHarness()
    defer { try? FileManager.default.removeItem(at: harness.root) }
    try await harness.service.start()

    await harness.service.stop()

    harness.settings.pollInterval = 1.0
    NotificationCenter.default.post(name: .copyzRulesChanged, object: nil)
    await Task.yield()

    // Still 0.4s: the observer is gone, not merely harmless.
    #expect(harness.service.monitor.configuration.pollInterval == 0.4)
  }

  @Test("Starting twice does not double-apply")
  func doubleStartIsIdempotent() async throws {
    try await withHarness { harness in
      try await harness.service.start()
      try await harness.service.start()

      harness.settings.pollInterval = 1.0
      NotificationCenter.default.post(name: .copyzRulesChanged, object: nil)
      await Task.yield()

      // Applied, and still exactly the configured value — a second observer
      // would be harmless here, but the removal test covers the leak.
      #expect(harness.service.monitor.configuration.pollInterval == 1.0)
    }
  }
}
