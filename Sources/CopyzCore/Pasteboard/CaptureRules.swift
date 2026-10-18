import Foundation

/// Compiled form of the user's regex exclusions.
///
/// `NSRegularExpression` is not `Sendable`, so compiled patterns are wrapped
/// explicitly instead of leaking into the `Sendable` rules value. The monitor
/// owns one of these and rebuilds it whenever `CaptureRules` changes.
public final class CompiledPatterns: @unchecked Sendable {
  private let expressions: [NSRegularExpression]

  public init(_ patterns: [String]) {
    expressions = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
  }

  public var isEmpty: Bool { expressions.isEmpty }

  public func matches(_ string: String) -> Bool {
    guard !expressions.isEmpty else { return false }
    let range = NSRange(string.startIndex..., in: string)
    return expressions.contains { $0.numberOfMatches(in: string, range: range) > 0 }
  }
}

/// User-configurable rules for what gets recorded.
///
/// The `org.nspasteboard.*` privacy markers are deliberately **not**
/// configurable. `ConcealedType` exists so a password manager can say "do not
/// keep this"; honouring it must never be something a settings toggle can
/// switch off.
public struct CaptureRules: Sendable, Equatable, Codable {
  /// Bundle identifiers never recorded.
  public var ignoredApps: Set<String> = []
  /// When non-empty, only these bundle identifiers are recorded.
  public var allowedApps: Set<String> = []
  /// Additional raw pasteboard type names to drop.
  public var extraIgnoredTypes: Set<String> = []
  /// Regexes matched against the plain-text payload; a match drops the clip.
  public var ignoredPatterns: [String] = []
  /// Master switch.
  public var isCapturing: Bool = true
  /// Skip image payloads.
  public var capturesImages: Bool = true
  /// Ignore copies arriving over Universal Clipboard / Handoff.
  public var ignoresUniversalClipboard: Bool = true

  public init() {}

  /// Why a copy was not recorded. Surfaced in the UI so "why didn't this get
  /// saved" is answerable instead of mysterious.
  public enum Rejection: Sendable, Equatable, CustomStringConvertible {
    case paused
    case privacyMarker(String)
    case noSubstantiveContent
    case appIgnored(String)
    case notAllowlisted(String)
    case typeIgnored(String)
    case patternMatched
    case imagesDisabled

    public var description: String {
      switch self {
      case .paused: "Capture is paused"
      case .privacyMarker(let t): "Marked confidential by \(t)"
      case .noSubstantiveContent: "Nothing worth storing"
      case .appIgnored(let b): "Ignored app: \(b)"
      case .notAllowlisted(let b): "App not in the allowlist: \(b)"
      case .typeIgnored(let t): "Ignored pasteboard type: \(t)"
      case .patternMatched: "Matched an ignore pattern"
      case .imagesDisabled: "Image capture is disabled"
      }
    }
  }

  /// Evaluates one candidate copy. `patterns` is the pre-compiled form of
  /// `ignoredPatterns`; the caller owns it so recompilation happens once per
  /// rule change rather than once per copy.
  public func rejection(
    types: Set<String>,
    bundleID: String?,
    text: String?,
    patterns: CompiledPatterns
  ) -> Rejection? {
    guard isCapturing else { return .paused }

    // Authoritative and non-overridable: the source app said not to record.
    for marker in PasteboardType.privacyMarkers.sorted(by: { $0.rawValue < $1.rawValue })
    where types.contains(marker.rawValue) {
      return .privacyMarker(marker.rawValue)
    }

    if ignoresUniversalClipboard, types.contains(PasteboardType.universalClipboard.rawValue) {
      return .typeIgnored(PasteboardType.universalClipboard.rawValue)
    }

    let substantive = PasteboardType.substantive.rawValues
    guard !types.isDisjoint(with: substantive) else { return .noSubstantiveContent }

    if !capturesImages, isImageOnly(types) { return .imagesDisabled }

    if let bundleID {
      if ignoredApps.contains(bundleID) { return .appIgnored(bundleID) }
      if !allowedApps.isEmpty, !allowedApps.contains(bundleID) {
        return .notAllowlisted(bundleID)
      }
    }

    if let hit = extraIgnoredTypes.intersection(types).sorted().first {
      return .typeIgnored(hit)
    }

    if let text, !text.isEmpty, patterns.matches(text) { return .patternMatched }

    return nil
  }

  /// True when the payload is only imagery — no text, no HTML, no files.
  private func isImageOnly(_ types: Set<String>) -> Bool {
    let images = Set(PasteboardType.imageKinds.map { $0.rawValue })
    guard !types.isDisjoint(with: images) else { return false }
    let textual = Set(PasteboardType.textualKinds.map { $0.rawValue })
    return types.isDisjoint(with: textual)
  }
}

extension Set where Element == PasteboardType {
  var rawValues: Set<String> { Set<String>(map { $0.rawValue }) }
}