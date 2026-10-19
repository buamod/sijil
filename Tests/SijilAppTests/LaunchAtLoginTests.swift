import Foundation
import SijilCore
import Testing

@testable import SijilApp

/// A stand-in registry that records calls instead of touching the system.
private final class FakeRegistry: LoginItemRegistering, @unchecked Sendable {
  private(set) var registered: Bool
  private(set) var calls: [String] = []
  var registerError: (any Error)?
  var unregisterError: (any Error)?

  init(registered: Bool = false) {
    self.registered = registered
  }

  var isRegistered: Bool { registered }

  func register() throws {
    if let registerError { throw registerError }
    registered = true
    calls.append("register")
  }

  func unregister() throws {
    if let unregisterError { throw unregisterError }
    registered = false
    calls.append("unregister")
  }
}

@Suite("Launch at login", .serialized)
struct LaunchAtLoginTests {
  @Test("Toggling the setting registers and unregisters for real")
  func toggleRegisters() throws {
    let fake = FakeRegistry()
    LaunchAtLogin.backend = fake
    defer { LaunchAtLogin.reset() }

    try LaunchAtLogin.set(true)
    #expect(fake.registered)
    try LaunchAtLogin.set(false)
    #expect(!fake.registered)
    #expect(fake.calls == ["register", "unregister"])
  }

  /// Swaps the process-global backend, so it cannot run beside another test
  /// that also swaps it.
  @Test("A refused registration is reported rather than swallowed")
  func refusalSurfaces() {
    struct Denied: LocalizedError { var errorDescription: String? { "not permitted" } }
    let fake = FakeRegistry()
    fake.registerError = Denied()
    LaunchAtLogin.backend = fake
    defer { LaunchAtLogin.reset() }

    #expect(throws: Denied.self) { try LaunchAtLogin.set(true) }
    #expect(!fake.registered)
  }
}

@MainActor
@Suite("Settings persistence", .serialized)
struct SettingsTests {
  private func isolatedDefaults() -> UserDefaults {
    let suite = "sijil.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  @Test("Login state is read from the system, not from a stale saved value")
  func loginStateComesFromSystem() {
    // A previous version stored `true` but never registered anything, so the
    // remembered value must not be authoritative.
    let defaults = isolatedDefaults()
    defaults.set(true, forKey: "launchAtLogin")

    let fake = FakeRegistry(registered: false)
    LaunchAtLogin.backend = fake
    defer { LaunchAtLogin.reset() }

    let settings = Settings(defaults: defaults)
    #expect(settings.launchAtLogin == false, "must reflect the registry, not defaults")
  }

  @Test("Changing the setting writes through to the registry")
  func changeWritesThrough() {
    let defaults = isolatedDefaults()
    let fake = FakeRegistry()
    LaunchAtLogin.backend = fake
    defer { LaunchAtLogin.reset() }

    let settings = Settings(defaults: defaults)
    settings.launchAtLogin = true

    #expect(fake.registered, "the toggle must actually register the login item")
    #expect(settings.launchAtLoginError == nil)
  }

  @Test("A refused change rolls the toggle back instead of lying")
  func refusalRollsBack() {
    struct Denied: LocalizedError { var errorDescription: String? { "not permitted" } }
    let defaults = isolatedDefaults()
    let fake = FakeRegistry()
    fake.registerError = Denied()
    LaunchAtLogin.backend = fake
    defer { LaunchAtLogin.reset() }

    let settings = Settings(defaults: defaults)
    settings.launchAtLogin = true

    #expect(settings.launchAtLogin == false, "the toggle must not show a state the system rejects")
    #expect(settings.launchAtLoginError == "not permitted")
  }

  @Test("A saved paused rule set never resurrects as paused")
  func pausedCaptureIsNotRestored() {
    let defaults = isolatedDefaults()
    var rules = CaptureRules()
    rules.isCapturing = false
    if let data = try? JSONEncoder().encode(rules) {
      defaults.set(data, forKey: "captureRules")
    }

    let settings = Settings(defaults: defaults)
    #expect(settings.rules.isCapturing, "a prior pause must not persist silently")
  }

  @Test("An explicit vault path is honoured")
  func vaultPathIsHonoured() {
    let defaults = isolatedDefaults()
    defaults.set("/tmp/sijil-vault", forKey: "vaultRootPath")

    let settings = Settings(defaults: defaults)
    #expect(settings.vaultURL.path == "/tmp/sijil-vault")
  }
}

/// sijil identifies itself to macOS by its code signature, and TCC ties the
/// Accessibility grant to it. With ad-hoc signing that means a rebuild looks
/// like a different app and the grant is revoked — which looks like "paste
/// randomly stopped working" unless something says otherwise.
@Suite("Signature identity")
struct SignatureIdentityTests {
  private func isolatedDefaults() -> UserDefaults {
    let suite = "sijil.sig.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  @Test("The first launch reports no change")
  func firstLaunchHasNoBaseline() {
    let defaults = isolatedDefaults()
    #expect(SignatureIdentity.recordLaunch(defaults: defaults, digest: "abc123") == .none)
  }

  @Test("Recording the same signature twice reports no change")
  func repeatedLaunchIsUnchanged() {
    let defaults = isolatedDefaults()
    #expect(SignatureIdentity.recordLaunch(defaults: defaults, digest: "abc123") == .none)
    #expect(SignatureIdentity.recordLaunch(defaults: defaults, digest: "abc123") == .unchanged)
  }

  @Test("A different signature is reported as a change")
  func differentSignatureIsAChange() {
    let defaults = isolatedDefaults()
    defaults.set("deadbeef-not-a-real-cdhash", forKey: "lastSeenCodeSignature")

    #expect(SignatureIdentity.recordLaunch(defaults: defaults, digest: "abc123") == .changed)
  }

  @Test("The recorded digest is updated so the change is reported once")
  func changeIsReportedOnce() {
    let defaults = isolatedDefaults()
    defaults.set("deadbeef-not-a-real-cdhash", forKey: "lastSeenCodeSignature")

    #expect(SignatureIdentity.recordLaunch(defaults: defaults, digest: "abc123") == .changed)
    // Second launch: the new digest is the baseline now, so no repeat nagging.
    #expect(SignatureIdentity.recordLaunch(defaults: defaults, digest: "abc123") == .unchanged)
  }

  @Test("An unreadable signature never claims a change")
  func unreadableSignatureIsSafe() {
    // The test process is not the signed bundle, so this is the real code path
    // when SecStaticCode fails. Claiming a change we cannot substantiate would
    // nag every launch.
    let defaults = isolatedDefaults()
    defaults.set("deadbeef", forKey: "lastSeenCodeSignature")
    #expect(SignatureIdentity.recordLaunch(defaults: defaults, digest: nil) == .none)
  }

  @Test("Only a real change produces a message")
  func explanationOnlyForChanges() {
    #expect(SignatureIdentity.explanation(for: .none) == nil)
    #expect(SignatureIdentity.explanation(for: .unchanged) == nil)
    #expect(SignatureIdentity.explanation(for: .changed)?.isEmpty == false)
  }

  @Test("The ad-hoc explanation names the actual cause and the fix")
  func adHocExplanationIsActionable() throws {
    guard SignatureIdentity.isAdHoc else {
      Issue.record("this build is not ad-hoc signed; the message differs")
      return
    }
    let message = try #require(SignatureIdentity.explanation(for: .changed))
    // The whole point is that the user knows *why* paste stopped working.
    #expect(message.contains("Accessibility"))
    #expect(message.contains("rebuild"))
    #expect(message.contains("make signing-key"))
  }
}

/// Renaming the app renamed its Application Support folder, which would
/// otherwise look like an empty history with no error and no way back.
@Suite("Legacy migration")
struct LegacyMigrationTests {
  @Test("The new folder is named after the app, not the old one")
  func currentFolderName() {
    #expect(LegacyMigration.applicationSupportRoot().lastPathComponent == "sijil")
    #expect(LegacyMigration.legacyFolderName == "copyz")
  }

  @Test("Nothing happens when there is no legacy folder")
  func noLegacyFolder() {
    let base = FileManager.default.temporaryDirectory
      .appending(path: "sijil-none-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: base) }

    // Explicit roots. Calling this without them reads the real Application
    // Support directory and would move the user's actual history.
    let outcome = LegacyMigration.migrateIfNeeded(
      legacy: base.appending(path: "copyz", directoryHint: .isDirectory),
      current: base.appending(path: "sijil", directoryHint: .isDirectory)
    )
    #expect(outcome == .none)
    #expect(LegacyMigration.notice(for: outcome) == nil)
  }

  @Test("Existing history is copied across, and the old folder is left alone")
  func copiesLegacyData() throws {
    let base = FileManager.default.temporaryDirectory
      .appending(path: "sijil-copy-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: base) }

    let legacy = base.appending(path: "copyz", directoryHint: .isDirectory)
    let clips = legacy.appending(path: "Vault/Clips", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
    try Data("note".utf8).write(to: clips.appending(path: "a.md"))
    try Data("note".utf8).write(to: clips.appending(path: "b.md"))
    try Data("db".utf8).write(to: legacy.appending(path: "history.sqlite"))

    let current = base.appending(path: "sijil", directoryHint: .isDirectory)
    let outcome = LegacyMigration.migrateIfNeeded(legacy: legacy, current: current)
    #expect(outcome == .migrated(fileCount: 2))

    // Everything moved...
    let moved = try FileManager.default.subpathsOfDirectory(atPath: current.path)
    #expect(moved.contains { $0.hasSuffix("a.md") })
    #expect(moved.contains { $0.hasSuffix("history.sqlite") })
    // ...and nothing was taken from the old folder.
    #expect(FileManager.default.fileExists(atPath: clips.appending(path: "a.md").path))
    #expect(FileManager.default.fileExists(atPath: legacy.appending(path: "history.sqlite").path))
  }

  @Test("It refuses to merge into an existing history")
  func refusesToMerge() throws {
    let base = FileManager.default.temporaryDirectory
      .appending(path: "sijil-merge-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: base) }

    let legacy = base.appending(path: "copyz", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: legacy.appending(path: "old-note.md"))

    let current = base.appending(path: "sijil", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    try Data("new".utf8).write(to: current.appending(path: "new-note.md"))

    // Interleaving two histories produces a mix with no way to tell them apart,
    // which is worse than leaving both folders alone for the user to merge.
    let outcome = LegacyMigration.migrateIfNeeded(legacy: legacy, current: current)
    #expect(outcome == .none)
    #expect(FileManager.default.fileExists(atPath: current.appending(path: "new-note.md").path))
    #expect(!FileManager.default.fileExists(atPath: current.appending(path: "old-note.md").path))
  }

  @Test("Only an actual change produces a notice")
  func noticeOnlyWhenSomethingMoved() {
    #expect(LegacyMigration.notice(for: .none) == nil)
    #expect(LegacyMigration.notice(for: .migrated(fileCount: 0)) != nil)
    #expect(LegacyMigration.notice(for: .migrated(fileCount: 3)) != nil)
    #expect(LegacyMigration.notice(for: .failed("disk full")) != nil)
  }

  @Test("The failure notice says nothing was deleted")
  func failureNoticeReassures() throws {
    let notice = try #require(LegacyMigration.notice(for: .failed("disk full")))
    // The whole safety property: a failed migration leaves the old data alone.
    #expect(notice.lowercased().contains("nothing was deleted"))
  }

  @Test("The success notice says the old folder was kept")
  func successNoticeReassures() throws {
    let notice = try #require(LegacyMigration.notice(for: .migrated(fileCount: 7)))
    #expect(notice.contains("7 clipboard items"))
    #expect(notice.lowercased().contains("left untouched"))
  }

  @Test("A single item is not pluralised")
  func singularItem() throws {
    let notice = try #require(LegacyMigration.notice(for: .migrated(fileCount: 1)))
    #expect(notice.contains("1 clipboard item"))
    #expect(!notice.contains("1 clipboard items"))
  }
}
