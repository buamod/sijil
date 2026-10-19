import Foundation
import Testing

@testable import SijilCore

/// The detector's contract is asymmetric, and the tests are written to match.
///
/// A **false negative** costs one extra stored secret. A **false positive** makes
/// something the user copied vanish from their history with no trace and no way
/// to recover it — silently, because the clip manager is a background service
/// they are not looking at. So the suite is weighted hard toward the benign
/// strings that must survive.
@Suite("Secret detection")
struct SecretDetectorTests {
  private let detector = SecretDetector()

  // MARK: - Must catch: unambiguous formats

  @Test("SSH private keys are detected")
  func sshPrivateKey() {
    let key = """
      -----BEGIN OPENSSH PRIVATE KEY-----
      b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtz
      c2gtZWQyNTUxOQAAACB7Xq8Qv3nZ0mKpLrT9wYcH1sJfD2gXeN5uR7bW4oQ==
      -----END OPENSSH PRIVATE KEY-----
      """
    #expect(detector.detect(in: key) == .sshPrivateKey)
  }

  @Test("A JWT is detected via its decoded header")
  func jwt() {
    // {"alg":"HS256","typ":"JWT"} / {"sub":"1234"} / signature
    let token =
      "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
      + ".eyJzdWIiOiIxMjM0NTY3ODkwIn0"
      + ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
    #expect(detector.detect(in: "Authorization: Bearer \(token)") == .jwt)
  }

  @Test("A bare JWT with no header prefix is still caught")
  func bareJWT() {
    let token =
      "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
      + ".eyJzdWIiOiIxMjM0NTY3ODkwIn0"
      + ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
    #expect(detector.detect(in: token) == .jwt)
  }

  @Test("Dotted text that is not a JWT survives")
  func dottedNonJWT() {
    // Three base64url-ish segments, but the first does not decode to a JWT
    // header. This is the shape most likely to cause a false positive.
    #expect(detector.detect(in: "com.example.app.alpha.beta.gamma") == nil)
    #expect(detector.detect(in: "1.2.3") == nil)
  }

  @Test("Provider API keys are detected")
  func providerKeys() {
    // Key lengths are derived, not hand-counted: a mistyped fixture would
    // silently stop testing the rule it exists to test.
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    #expect(detector.detect(in: "AKIAIOSFODNN7EXAMPLE") == .awsAccessKey)
    #expect(detector.detect(in: "ghp_" + String(alphabet.prefix(40))) == .githubToken)
    #expect(detector.detect(in: "xoxb-123456789012-abcdefghijklmnop") == .slackToken)
    #expect(detector.detect(in: "sk_live_" + String(alphabet.prefix(24))) == .stripeKey)
    #expect(detector.detect(in: "sk-ant-api03-" + String(alphabet.prefix(80))) == .anthropicKey)
    #expect(detector.detect(in: "sk-proj-" + String(alphabet.prefix(48))) == .openAIKey)
    #expect(detector.detect(in: "AIza" + String(alphabet.prefix(35))) == .googleAPIKey)
  }

  @Test("Keys one character short of the real length are not detected")
  func nearMissKeysSurvive() {
    // Guards against a regex that quietly became more permissive than intended.
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    #expect(detector.detect(in: "AIza" + String(alphabet.prefix(34))) == nil)
    #expect(detector.detect(in: "ghp_" + String(alphabet.prefix(35))) == nil)
  }

  @Test("A Stripe publishable key is not a secret")
  func publishableStripeKey() {
    // `pk_` is designed to be public; treating it as a secret would drop
    // ordinary front-end code the user legitimately copies.
    #expect(detector.detect(in: "pk_live_4eC39HqLyjWDarjtT1zdp7dc") == nil)
  }

  @Test("URLs with embedded credentials are detected")
  func basicAuthURL() {
    #expect(detector.detect(in: "https://admin:s3cr3t@example.com/dashboard") == .basicAuthURL)
    #expect(
      detector.detect(in: "postgres://user:hunter2@db.internal:5432/app") == .connectionString)
    #expect(detector.detect(in: "mysql://root:rootpw@localhost/mydb?password=abc123xyz") != nil)
  }

  @Test("A URL port is not a password")
  func urlPortIsNotAPassword() {
    #expect(detector.detect(in: "http://localhost:8080/health") == nil)
    #expect(detector.detect(in: "https://example.com:443/path") == nil)
  }

  @Test("Card numbers are detected via Luhn")
  func cardNumbers() {
    #expect(detector.detect(in: "4111 1111 1111 1111") == .luhnCard)
    #expect(detector.detect(in: "5500-0000-0000-0004") == .luhnCard)
    #expect(detector.detect(in: "378282246310005") == .luhnCard)
  }

  // MARK: - Must not catch: the false-positive surface

  @Test("Ordinary prose and code survive")
  func benignProse() {
    let samples = [
      "The password reset link expires in 30 minutes.",
      "Set your password to something long and unique.",
      "Bearer of bad news, bearer of good news.",
      "AWS credentials are stored in ~/.aws/credentials",
      "See https://developer.apple.com/documentation/security for details.",
      "git commit -m 'fix token refresh'",
      "func fetchToken() async throws -> Token { }",
      "const API_KEY = process.env.API_KEY",
      "curl -H 'Authorization: Bearer <your-token-here>' https://api.example.com",
      "TODO: rotate the secret before the demo on Friday",
    ]
    for sample in samples {
      #expect(detector.detect(in: sample) == nil, "false positive: \(sample)")
    }
  }

  @Test("Numbers that are not card numbers survive")
  func benignNumbers() {
    let samples = [
      "1234567890123456",
      "Order number 20261018123456 shipped today",
      "ISBN 978-0-306-40615-7",
      "2026-10-18T21:16:25.507Z",
      "Build 4521 passed in 3.21 seconds",
      "8675309",
      "1,234,567,890,123",
    ]
    for sample in samples {
      #expect(detector.detect(in: sample) == nil, "false positive: \(sample)")
    }
  }

  @Test("Placeholders in config files are not secrets")
  func configPlaceholders() {
    // Real .env and compose files look exactly like this, and are copied often.
    let samples = [
      #"password: changeme"#,
      #"password="changeme""#,
      #"DB_PASSWORD=please-change-me"#,
      #"api_key: your-api-key-here"#,
      #"secret: xxxxxxxxxxxxxxxx"#,
      #"token: null"#,
      #"password=true"#,
      #"auth: basic"#,
    ]
    for sample in samples {
      #expect(detector.detect(in: sample) == nil, "false positive: \(sample)")
    }
  }

  @Test("UUIDs, hashes, and base64 blobs survive")
  func benignIdentifiers() {
    let samples = [
      "550e8400-e29b-41d4-a716-446655440000",
      "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA",
      "git commit 8f3a91b2c4d5e6f7",
      "10.0.0.1",
      "192.168.1.100:8080",
    ]
    for sample in samples {
      #expect(detector.detect(in: sample) == nil, "false positive: \(sample)")
    }
  }

  @Test("Source code is not mistaken for credentials")
  func benignCode() {
    let samples = [
      "let token = await session.refreshToken",
      "self.password = textField.stringValue ?? \"\"",
      "struct APIKey: Codable { let key: String }",
      "if password.count >= 12 { validate(password) }",
      "http://internal-api.local:8443/v1/healthcheck",
      "npm install --save-dev jsonwebtoken",
    ]
    for sample in samples {
      #expect(detector.detect(in: sample) == nil, "false positive: \(sample)")
    }
  }

  @Test("Very long text is not scanned")
  func oversizedTextSkipped() {
    // A whole file pasted into the terminal is a normal thing to do, and
    // scanning megabytes on the pasteboard thread would stall capture.
    let huge = String(repeating: "AKIAIOSFODNN7EXAMPLE ", count: 30_000)
    #expect(detector.detect(in: huge) == nil)
  }

  @Test("Empty text is not a secret")
  func emptyText() {
    #expect(detector.detect(in: "") == nil)
  }

  // MARK: - Keyword-anchored

  @Test("A high-entropy assignment to a secret-like name is caught")
  func secretAssignment() {
    let samples = [
      #"password = "Xk9#mQ2vLp4Zn8"  "#,
      "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      "api_key: aG7Kp2Lm9Qx4Rt8Yw3Zs6Bn1Cv5Dq",
      "client_secret=f3a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5",
    ]
    for sample in samples {
      #expect(
        detector.detect(in: sample) == .secretAssignment,
        "missed: \(sample)"
      )
    }
  }

  @Test("Low-entropy assignments are left alone")
  func weakAssignmentsSurvive() {
    let samples = [
      #"password = "hunter2""#,  // classic placeholder
      "password: correcthorse",  // two dictionary words
      "secret = mysecret",  // repeats itself
      "token: undefined",
      "auth = Bearer",
    ]
    for sample in samples {
      #expect(detector.detect(in: sample) == nil, "false positive: \(sample)")
    }
  }

  // MARK: - Helpers

  @Test("Luhn validation is correct")
  func luhn() {
    #expect(SecretDetector.passesLuhn("4111111111111111"))
    #expect(SecretDetector.passesLuhn("5500000000000004"))
    #expect(!SecretDetector.passesLuhn("4111111111111112"))
    #expect(!SecretDetector.passesLuhn("1234567890123456"))
  }

  @Test("Entropy heuristic rejects placeholders and accepts secrets")
  func entropyHeuristic() {
    #expect(SecretDetector.looksRandom("Xk9#mQ2vLp4Zn8"))
    #expect(SecretDetector.looksRandom("wJalrXUtnFEMIK7MDENGbPxRfiCY"))
    #expect(!SecretDetector.looksRandom("changeme"))
    #expect(!SecretDetector.looksRandom("aaaaaaaaaaaaaa"))
    #expect(!SecretDetector.looksRandom("hunter2"))
  }

  @Test("Every password manager in the list is a real bundle id")
  func bundleIDsAreWellFormed() {
    for id in SecretDetector.passwordManagerBundleIDs {
      #expect(id.contains("."), "malformed bundle id: \(id)")
      #expect(!id.hasSuffix("."))
      #expect(id.count > 5)
    }
  }
}

/// The detector's effect on real capture, not just its output.
@Suite("Secret handling in capture")
struct SecretCaptureTests {
  private func compiled() -> CompiledPatterns {
    CompiledPatterns([])
  }

  @Test("Safari is not treated as a password manager")
  func safariIsNotAPasswordManager() {
    // Users copy URLs from Safari constantly. Dropping them would be the single
    // most annoying false positive possible.
    #expect(!SecretDetector.passwordManagerBundleIDs.contains("com.apple.Safari"))
    #expect(!SecretDetector.passwordManagerBundleIDs.contains("com.tinyspeck.slackmacgap"))
    #expect(!SecretDetector.passwordManagerBundleIDs.contains("com.raycast.macos"))
  }

  @Test("A known password manager bundle is dropped regardless of content")
  func knownManagerDropped() {
    var rules = CaptureRules()
    for bundleID in SecretDetector.passwordManagerBundleIDs {
      #expect(
        rules.rejection(
          types: ["public.utf8-plain-text"],
          bundleID: bundleID,
          text: "just some text",
          patterns: compiled()
        ) == .passwordManager(bundleID),
        "not dropped: \(bundleID)"
      )
    }
  }

  @Test("Secret detection can be turned off")
  func detectionCanBeDisabled() {
    var rules = CaptureRules()
    rules.detectsSecrets = false
    #expect(
      rules.rejection(
        types: ["public.utf8-plain-text"],
        bundleID: "com.apple.Terminal",
        text: "AKIAIOSFODNN7EXAMPLE",
        patterns: compiled()
      ) == nil
    )
  }

  @Test("A secret copied from a normal app is still dropped")
  func secretFromTerminalDropped() {
    let rules = CaptureRules()
    let rejection = rules.rejection(
      types: ["public.utf8-plain-text"],
      bundleID: "com.apple.Terminal",
      text: "export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE",
      patterns: compiled()
    )
    #expect(rejection == .secretDetected(.awsAccessKey))
  }

  @Test("Ordinary text from a normal app is kept")
  func benignTextKept() {
    let rules = CaptureRules()
    #expect(
      rules.rejection(
        types: ["public.utf8-plain-text"],
        bundleID: "com.apple.Safari",
        text: "https://example.com/docs/getting-started",
        patterns: compiled()
      ) == nil
    )
  }

  @Test("The privacy marker still wins over everything")
  func privacyMarkerWins() {
    let rules = CaptureRules()
    #expect(
      rules.rejection(
        types: ["org.nspasteboard.ConcealedType", "public.utf8-plain-text"],
        bundleID: "com.apple.Terminal",
        text: "anything",
        patterns: compiled()
      ) == .privacyMarker("org.nspasteboard.ConcealedType")
    )
  }
}
