import CopyzCore
import Foundation
import Testing

@testable import CopyzApp

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
    let suite = "copyz.tests.\(UUID().uuidString)"
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
    defaults.set("/tmp/copyz-vault", forKey: "vaultRootPath")

    let settings = Settings(defaults: defaults)
    #expect(settings.vaultURL.path == "/tmp/copyz-vault")
  }
}

/// copyz identifies itself to macOS by its code signature, and TCC ties the
/// Accessibility grant to it. With ad-hoc signing that means a rebuild looks
/// like a different app and the grant is revoked — which looks like "paste
/// randomly stopped working" unless something says otherwise.
@Suite("Signature identity")
struct SignatureIdentityTests {
  private func isolatedDefaults() -> UserDefaults {
    let suite = "copyz.sig.\(UUID().uuidString)"
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
