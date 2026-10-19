import CopyzPaste
import Foundation
import Security

/// Detects a signature change across launches.
///
/// With ad-hoc signing, TCC identifies copyz by the binary's CDHash. Rebuilding
/// produces a different hash, so macOS treats the new binary as a different app
/// and revokes the Accessibility grant. From the user's side that is just
/// "pasting stopped working and I have no idea why".
///
/// Remembering the hash lets copyz say so, once, with the actual cause.
public enum SignatureIdentity {
  private static let defaultsKey = "lastSeenCodeSignature"

  /// The current binary's code signature digest, or nil if it cannot be read.
  public static var currentDigest: String? {
    // The executable's own bundle, not the .app: this runs inside the process and
    // may be launched from a bundle that has since been replaced on disk.
    guard
      let selfPath = Bundle.main.executableURL?
        .resolvingSymlinksInPath().path
    else { return nil }

    var staticCode: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(URL(fileURLWithPath: selfPath) as CFURL, [], &staticCode)
        == errSecSuccess,
      let staticCode
    else { return nil }

    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &info
      ) == errSecSuccess,
      let dictionary = info as? [String: Any]
    else { return nil }

    return dictionary["cdhash"] as? String
  }

  /// Whether this identity is stable across rebuilds.
  ///
  /// An ad-hoc signature has no Team ID, so there is nothing but the CDHash to
  /// identify the app by.
  public static var isStableIdentity: Bool { !isAdHoc }

  /// Whether the binary is ad-hoc signed.
  public static var isAdHoc: Bool {
    // `TeamIdentifier` is absent for ad-hoc signatures.
    (currentTeamIdentifier ?? "") == ""
  }

  private static var currentTeamIdentifier: String? {
    guard
      let selfPath = Bundle.main.executableURL?.resolvingSymlinksInPath().path
    else { return nil }
    var staticCode: SecStaticCode?
    guard
      SecStaticCodeCreateWithPath(URL(fileURLWithPath: selfPath) as CFURL, [], &staticCode)
        == errSecSuccess,
      let staticCode
    else { return nil }
    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        == errSecSuccess,
      let dictionary = info as? [String: Any]
    else { return nil }
    return dictionary["teamid"] as? String
  }

  /// Outcome of comparing this launch against the previous one.
  public enum Change: Equatable {
    /// First launch, or nothing recorded.
    case none
    /// Same binary as last time.
    case unchanged
    /// A different binary ran since last time.
    case changed
  }

  /// Compares the current signature against the last launch and records this one.
  ///
  /// Call once per launch. Whether to *mention* a change is the caller's call:
  /// there is no way to know retroactively whether a grant existed, since
  /// revocation is precisely what made `Accessibility.isTrusted` false.
  ///
  /// `digest` is injectable because the test process is not the signed bundle:
  /// `SecStaticCodeCreateWithPath` finds no code signature there, so reading the
  /// real one would make every branch of this unreachable under test.
  @discardableResult
  public static func recordLaunch(
    defaults: UserDefaults = .standard,
    digest override: String? = nil
  ) -> Change {
    guard let digest = override ?? currentDigest else { return .none }

    let previous = defaults.string(forKey: defaultsKey)
    defaults.set(digest, forKey: defaultsKey)

    guard let previous else { return .none }
    return previous == digest ? .unchanged : .changed
  }

  /// Human-readable explanation, or nil when there is nothing to say.
  public static func explanation(for change: Change, defaults: UserDefaults = .standard) -> String?
  {
    guard change == .changed else { return nil }

    if isAdHoc {
      return "copyz was rebuilt, so macOS revoked its Accessibility permission. "
        + "Synthetic paste will not work until you grant it again in "
        + "System Settings ▸ Privacy & Security ▸ Accessibility.\n\n"
        + "To stop this happening, run `make signing-key` once and rebuild."
    }
    return "copyz's signature changed since the last launch. If paste has stopped "
      + "working, re-grant Accessibility in System Settings ▸ Privacy & Security."
  }
}
