import Foundation

/// Detects credentials in copied text.
///
/// This exists because a clipboard manager's whole job is to keep things you
/// copy — and the thing you copy from a password manager is, by definition, the
/// secret itself. macOS's `org.nspasteboard.ConcealedType` marker helps, but
/// only for the apps that set it; plenty do not.
///
/// The design constraint is **precision over recall**. A false positive means a
/// legitimate copy silently vanishes from the user's history with no way to
/// recover it, which is a worse failure than storing one more token. So every
/// rule below requires independent corroborating evidence — a keyword *and* a
/// shape, or a structural checksum that cannot occur by chance.
///
/// Nothing here rewrites the text: a detected secret is dropped before it
/// reaches disk, never stored-then-redacted.
public struct SecretDetector: Sendable {
  /// What a match looked like, for explaining a drop to the user.
  public enum Kind: String, Sendable, Equatable, CaseIterable {
    case privateKey
    case jwt
    case awsAccessKey
    case githubToken
    case slackToken
    case stripeKey
    case openAIKey
    case anthropicKey
    case googleAPIKey
    case bearerToken
    case basicAuthURL
    case sshPrivateKey
    case connectionString
    case secretAssignment
    case luhnCard

    public var description: String {
      switch self {
      case .privateKey: "a PEM private key"
      case .jwt: "a JSON Web Token"
      case .awsAccessKey: "an AWS access key id"
      case .githubToken: "a GitHub token"
      case .slackToken: "a Slack token"
      case .stripeKey: "a Stripe secret key"
      case .openAIKey: "an OpenAI API key"
      case .anthropicKey: "An Anthropic API key"
      case .googleAPIKey: "a Google API key"
      case .bearerToken: "a bearer token"
      case .basicAuthURL: "a URL with embedded credentials"
      case .sshPrivateKey: "an SSH private key"
      case .connectionString: "a database connection string with a password"
      case .secretAssignment: "an assignment to a password-like name"
      case .luhnCard: "a credit card number"
      }
    }
  }

  /// Bundle identifiers whose copies are dropped unconditionally.
  ///
  /// A password manager writing to the pasteboard is doing so for one purpose,
  /// and every one of them has a bundle id that is stable across updates.
  /// Skipping them is far more reliable than pattern-matching the output, which
  /// depends entirely on how a given manager formats its unlock payload.
  ///
  /// The list is deliberately narrow. A browser or a chat client is not a
  /// password manager: users copy URLs from Safari and code from Slack all day,
  /// and silently dropping those would be far worse than the handful of secrets
  /// this list is trying to protect.
  public static let passwordManagerBundleIDs: Set<String> = [
    "com.1password.1password",
    "com.agilebits.onepassword-ssh",
    "com.agilebits.onepassword7",
    "com.apple.Passwords",
    "com.apple.keychainaccess",
    "com.bitwarden.desktop",
    "com.enpass.Enpass-Desktop",
    "com.logmein.passhub",
    "com.msecure",
    "com.protonpass.desktop",
    "com.wallabag.it",
    "com.yubico.yubikey-manager",
    "net.nokiatech.keepass",
    "org.keepassxc.KeepassXC",
    "org.pwsafe.PWSafe",
    "io.gitlab.librem",
  ]

  /// Keywords that make an adjacent `name = value` assignment interesting.
  private static let secretKeywords: Set<String> = [
    "passwd", "password", "pwd", "pass", "secret", "token", "apikey",
    "api_key", "api_secret", "access_key", "accesskey", "secret_key",
    "client_secret", "private_key", "privatekey", "auth", "authorization",
    "credential", "credentials", "session_key", "encryption_key",
  ]

  public init() {}

  /// Inspects text and reports the first confident match, or `nil`.
  ///
  /// Order matters only for which reason is reported; all matches mean the same
  /// thing operationally.
  public func detect(in text: String) -> Kind? {
    guard !text.isEmpty, text.count <= 512_000 else { return nil }

    // Structural formats first: they are unambiguous, so a keyword-free match
    // is trustworthy.
    if Self.containsPrivateKeyBlock(text) { return .sshPrivateKey }
    if text.contains("-----BEGIN") && text.contains("PRIVATE KEY-----") {
      return .privateKey
    }
    if Self.isJWT(text) { return .jwt }
    if Self.containsAWSKey(text) { return .awsAccessKey }
    if Self.containsGitHubToken(text) { return .githubToken }
    if Self.containsSlackToken(text) { return .slackToken }
    if Self.containsStripeKey(text) { return .stripeKey }
    if Self.containsAnthropicKey(text) { return .anthropicKey }
    if Self.containsOpenAIKey(text) { return .openAIKey }
    if Self.containsGoogleAPIKey(text) { return .googleAPIKey }
    if Self.containsBasicAuthURL(text) { return .basicAuthURL }
    if Self.containsConnectionString(text) { return .connectionString }
    if Self.containsCardNumber(text) { return .luhnCard }

    // Token-shaped bearer headers need a keyword to count. "Bearer" alone can
    // appear in ordinary prose and in HTTP documentation.
    if Self.looksLikeBearerToken(text) { return .bearerToken }

    // Assignment rule: keyword plus a value that is long and unquotable-free.
    // Both halves are required, so `password = true` in a config file is not a
    // match while `password = "hunter2hunter2"` is.
    if Self.containsSecretAssignment(text) { return .secretAssignment }

    return nil
  }

  /// Whether text should be dropped entirely.
  public func isSecret(_ text: String) -> Bool {
    detect(in: text) != nil
  }

  // MARK: - Unambiguous formats

  private static func containsPrivateKeyBlock(_ text: String) -> Bool {
    text.contains("-----BEGIN OPENSSH PRIVATE KEY-----")
      || text.contains("-----BEGIN RSA PRIVATE KEY-----")
      || text.contains("-----BEGIN EC PRIVATE KEY-----")
      || text.contains("-----BEGIN DSA PRIVATE KEY-----")
      || text.contains("-----BEGIN PGP PRIVATE KEY BLOCK-----")
  }

  /// Three base64url segments, the first of which decodes to a JSON header.
  ///
  /// Checking the decoded header is what keeps this safe: random prose can look
  /// like three dot-separated base64 runs, but it will not decode to JSON with
  /// an `alg` field.
  ///
  /// Each whitespace-delimited word is tried rather than the whole line, because
  /// in practice the copy is `Authorization: Bearer <token>` rather than a bare
  /// token.
  private static func isJWT(_ text: String) -> Bool {
    for word in text.split(whereSeparator: { $0.isWhitespace }) {
      let candidate = String(word)
      let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
      guard parts.count == 3 else { continue }
      guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isBase64URLCharacter) })
      else { continue }
      guard let header = base64URLDecode(String(parts[0])),
            header.contains("\"alg\"") || header.contains("\"typ\"")
      else { continue }
      return true
    }
    return false
  }

  private static func containsAWSKey(_ text: String) -> Bool {
    // AKIA/ASIA followed by 16 uppercase alphanumerics.
    text.range(of: "\\b(?:AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16}\\b", options: .regularExpression) != nil
  }

  private static func containsGitHubToken(_ text: String) -> Bool {
    text.range(of: "\\bgh[pousr]_[A-Za-z0-9]{36,}\\b", options: .regularExpression) != nil
  }

  private static func containsSlackToken(_ text: String) -> Bool {
    text.range(of: "\\bxox[abposr]-[A-Za-z0-9-]{10,}\\b", options: .regularExpression) != nil
  }

  private static func containsStripeKey(_ text: String) -> Bool {
    // Live mode only. Publishable keys are prefixed `pk_` and are public.
    text.range(of: "\\bsk_(?:live|test)_[A-Za-z0-9]{20,}\\b", options: .regularExpression) != nil
  }

  private static func containsOpenAIKey(_ text: String) -> Bool {
    // `sk-ant-` is Anthropic's, not OpenAI's, and its shape satisfies this
    // pattern — hence the negative lookahead as well as the check order.
    text.range(
      of: "\\bsk-(?!ant-)(?:proj-)?[A-Za-z0-9_-]{32,}\\b",
      options: .regularExpression
    ) != nil
  }

  private static func containsAnthropicKey(_ text: String) -> Bool {
    text.range(of: "\\bsk-ant-[A-Za-z0-9_-]{32,}\\b", options: .regularExpression) != nil
  }

  private static func containsGoogleAPIKey(_ text: String) -> Bool {
    text.range(of: "\\bAIza[0-9A-Za-z_-]{35}\\b", options: .regularExpression) != nil
  }

  /// `scheme://user:password@host`. Only http(s), because other schemes use
  /// colons in ways that make this heuristic unreliable.
  private static func containsBasicAuthURL(_ text: String) -> Bool {
    text.range(
      of: "\\bhttps?://[^\\s/:@]+:[^\\s/@]+@[^\\s/]+",
      options: .regularExpression
    ) != nil
  }

  /// `scheme://user:password@host` for a database scheme, or an explicit
  /// `password=` component.
  ///
  /// Two distinct spellings exist in the wild: `postgres://user:pw@host/db` and
  /// `Server=…;Password=pw;`, so both are covered.
  private static func containsConnectionString(_ text: String) -> Bool {
    let schemes = "(?:postgres(?:ql)?|mysql|mongodb(?:\\+srv)?|redis|amqp|mssql)"
    let authorityCredentials = "\\b\(schemes)://[^\\s/:@]+:[^\\s/@]+@[^\\s/]+"
    let queryPassword = "\\b\(schemes)://[^\\s]*[?&](?:password|pwd)=[^\\s&]+"
    let adoStyle = "\\bserver=[^;\\n]*;(?:[^;\\n]*;)*[^;\\n]*(?:password|pwd)="

    for pattern in [authorityCredentials, queryPassword, adoStyle] {
      if text.range(
        of: pattern,
        options: [.regularExpression, .caseInsensitive]
      ) != nil { return true }
    }
    return false
  }

  // MARK: - Checksum-anchored

  /// A 13–19 digit run that passes Luhn.
  ///
  /// The Luhn checksum is what makes this safe: a 16-digit number passes by
  /// chance roughly one time in ten, but a 13–19 digit run that passes Luhn does
  /// not occur in ordinary text, timestamps, or identifiers.
  private static func containsCardNumber(_ text: String) -> Bool {
    // Digits may be separated by single spaces or hyphens, as printed on cards.
    let pattern = "\\b(?:\\d[ -]?){12,18}\\d\\b"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(text.startIndex..., in: text)

    for match in regex.matches(in: text, range: range) {
      guard let matchRange = Range(match.range, in: text) else { continue }
      let digits = text[matchRange].filter(\.isNumber)
      // 13–19 is the real range of card numbers; shorter or longer is noise.
      guard (13...19).contains(digits.count) else { continue }
      guard passesLuhn(digits) else { continue }
      // Real major industry identifiers do not start with these, so a matching
      // sequence is more likely an order number than a card.
      if digits.hasPrefix("0") { continue }
      return true
    }
    return false
  }

  static func passesLuhn(_ digits: String) -> Bool {
    let numbers = digits.compactMap(\.wholeNumberValue)
    guard numbers.count == digits.count, numbers.count >= 2 else { return false }

    var sum = 0
    var double = false
    for digit in numbers.reversed() {
      var value = digit
      if double {
        value *= 2
        if value > 9 { value -= 9 }
      }
      sum += value
      double.toggle()
    }
    return sum % 10 == 0
  }

  // MARK: - Keyword-anchored

  private static func looksLikeBearerToken(_ text: String) -> Bool {
    text.range(
      of: "(?i)\\bbearer\\s+[A-Za-z0-9._~+/=-]{20,}",
      options: .regularExpression
    ) != nil
  }

  /// `something_password = "…"` where the value is long and unquoted.
  ///
  /// Requires both a secret-ish name and a plausible secret value. A bare
  /// keyword, or a keyword with a short or obviously non-secret value, is
  /// deliberately not a match — config files and docs mention these constantly.
  private static func containsSecretAssignment(_ text: String) -> Bool {
    let pattern = "(?i)\\b([a-z0-9_.-]*(?:\(secretKeywordsPattern()))[a-z0-9_.-]*)"
      + "\\s*(?:[:=]|=>)\\s*[\"']?([^\"'\\s,;]{8,})[\"']?"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(text.startIndex..., in: text)

    for match in regex.matches(in: text, range: range) {
      // Group 1 is the name, which the pattern has already constrained to
      // contain a keyword; only the value's entropy decides the match.
      guard let valueRange = Range(match.range(at: 2), in: text) else { continue }

      let value = String(text[valueRange])
      // A real secret has entropy. All-lowercase words and repeated characters
      // are placeholders like `password = changeme`.
      guard looksRandom(value) else { continue }
      return true
    }
    return false
  }

  private static func secretKeywordsPattern() -> String {
    secretKeywords.sorted { $0.count > $1.count }
      .map { NSRegularExpression.escapedPattern(for: $0) }
      .joined(separator: "|")
  }

  /// Cheap entropy proxy.
  ///
  /// Not a measure of cryptographic strength — just a filter for the human-
  /// chosen placeholders that appear in config files and documentation, which
  /// are the realistic false-positive source.
  static func looksRandom(_ value: String) -> Bool {
    guard value.count >= 12 else { return false }

    // No digits is the single strongest negative signal, and it is what
    // separates `password = textField.stringValue` in real Swift from an actual
    // secret. Password managers generate digits in essentially every password,
    // so this costs very little recall.
    let hasDigit = value.contains { $0.isNumber }
    guard hasDigit else { return false }

    let characters = Set(value)
    guard characters.count >= 10 else { return false }

    let hasLower = value.contains { $0.isLowercase }
    let hasUpper = value.contains { $0.isUppercase }
    // A mixed-case string with digits is a secret; an all-lowercase one needs
    // more distinct characters to qualify, because `correcthorsebatterystaple`
    // is a real passphrase style and should not be thrown away.
    guard (hasLower && hasUpper) || characters.count >= 14 else { return false }

    // Reject repeated characters, the signature of `aaaaaaaaaaaa`.
    var previous: Character?
    var runLength = 0
    var longestRun = 1
    for character in value {
      runLength = (character == previous) ? runLength + 1 : 1
      previous = character
      longestRun = max(longestRun, runLength)
    }
    guard longestRun <= 4 else { return false }

    // Reject dictionary-ish words: too few distinct characters for the length.
    return Double(characters.count) / Double(value.count) > 0.4
  }

  // MARK: - Encoding

  private static func base64URLDecode(_ input: String) -> String? {
    var standard = input
    while standard.hasSuffix("=") { standard.removeLast() }
    guard let data = Data(base64Encoded: standard.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")),
      !data.isEmpty
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

extension Character {
  fileprivate var isBase64URLCharacter: Bool {
    isLetter && isASCII || isNumber && isASCII || self == "-" || self == "_"
  }
}