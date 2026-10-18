import AppKit
import Foundation
import Testing

@testable import CopyzCore

/// End-to-end tests through the real pasteboard plumbing.
///
/// These exist because `CaptureRules.rejection` was thoroughly unit-tested while
/// the extractor never passed it any text — the rules call ran before the
/// payload was read — so every secret-detection test passed and the feature was
/// nonetheless completely inert in the running app.
///
/// A uniquely-named `NSPasteboard` behaves like the system one but is private
/// to this process, so it needs no TCC grant and cannot disturb the user's real
/// clipboard. That isolation is what makes this testable at all.
@MainActor
@Suite("Capture pipeline")
struct CapturePipelineTests {
  private func makeItem(
    text: String,
    source: String = "com.apple.Terminal",
    extraTypes: [String: Data] = [:]
  ) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    for (type, data) in extraTypes {
      item.setData(data, forType: NSPasteboard.PasteboardType(type))
    }
    // The source bundle id is only recorded when the pasteboard was written by
    // another process, so it is asserted via the extractor parameter directly.
    _ = source
    return item
  }

  private func extract(
    _ items: [NSPasteboardItem],
    bundleID: String? = "com.apple.Terminal",
    rules: CaptureRules = CaptureRules()
  ) -> (item: ClipItem, rejection: CaptureRules.Rejection?)? {
    PasteboardExtractor.makeItem(
      from: items,
      sourceBundleID: bundleID,
      sourceAppName: "Terminal",
      rules: rules,
      patterns: CompiledPatterns(rules.ignoredPatterns)
    )
  }

  // MARK: - Secrets

  @Test("An AWS key on the pasteboard is dropped, not stored")
  func awsKeyDropped() {
    let outcome = extract([
      makeItem(text: "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE"),
    ])
    #expect(outcome?.rejection == .secretDetected(.awsAccessKey))
    #expect(outcome?.item.contents.isEmpty == true, "nothing may reach the store")
  }

  @Test("A private key paste is dropped")
  func privateKeyDropped() {
    let key = """
      -----BEGIN RSA PRIVATE KEY-----
      MIIEowIBAAKCAQEAx0Z0Z8Q1t5p3r7m2v9b4c6d8f0h2j4l6n8p0r2t4v6x8z0
      -----END RSA PRIVATE KEY-----
      """
    #expect(extract([makeItem(text: key)])?.rejection == .secretDetected(.sshPrivateKey))
  }

  @Test("A card number paste is dropped")
  func cardDropped() {
    #expect(
      extract([makeItem(text: "card 4111 1111 1111 1111 exp 12/29")])?.rejection
        == .secretDetected(.luhnCard)
    )
  }

  @Test("Ordinary text still gets through")
  func ordinaryTextCaptured() {
    let outcome = extract([
      makeItem(text: "https://github.com/foo/barbaz1234/pull/5678"),
    ])
    #expect(outcome?.rejection == nil)
    #expect(outcome?.item.contents.count == 1)
  }

  @Test("Turning detection off lets the secret through")
  func detectionOffAllowsSecret() {
    var rules = CaptureRules()
    rules.detectsSecrets = false
    let outcome = extract(
      [makeItem(text: "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE")],
      rules: rules
    )
    #expect(outcome?.rejection == nil)
    #expect(outcome?.item.contents.count == 1)
  }

  @Test("One secret in a multi-item paste drops the whole copy")
  func secretAnywhereDropsEverything() {
    let outcome = extract([
      makeItem(text: "harmless first line"),
      makeItem(text: "AKIAIOSFODNN7EXAMPLE"),
    ])
    #expect(outcome?.rejection == .secretDetected(.awsAccessKey))
    #expect(outcome?.item.contents.isEmpty == true)
  }

  @Test("A password manager's copy is dropped without inspecting the text")
  func passwordManagerDropped() {
    // Content the detector would not recognise at all. The bundle check is the
    // only thing standing between this and the user's history.
    let outcome = extract(
      [makeItem(text: "◆ my vault entry")],
      bundleID: "com.1password.1password"
    )
    #expect(outcome?.rejection == .passwordManager("com.1password.1password"))
  }

  @Test("The privacy marker still wins over secret detection")
  func privacyMarkerPrecedence() {
    let item = makeItem(text: "AKIAIOSFODNN7EXAMPLE")
    item.setData(
      Data("x".utf8),
      forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    )
    let outcome = extract([item])
    #expect(outcome?.rejection == .privacyMarker("org.nspasteboard.ConcealedType"))
  }

  // MARK: - Non-text payloads

  @Test("An image copy is unaffected by text rules")
  func imageCopyUnaffected() {
    // A PNG's bytes are not text, so nothing should be pattern-matched against
    // it — and nothing should be lost either.
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    let item = NSPasteboardItem()
    item.setData(png, forType: .png)
    let outcome = extract([item])
    #expect(outcome?.rejection == nil)
    #expect(outcome?.item.contents.count == 1)
  }

  @Test("An ignore pattern still applies alongside secret detection")
  func patternStillApplies() {
    var rules = CaptureRules()
    rules.ignoredPatterns = ["^DONE-"]
    let outcome = extract([makeItem(text: "DONE-12345")], rules: rules)
    #expect(outcome?.rejection == .patternMatched)
  }

  // MARK: - Real pasteboard

  @Test("A private pasteboard round-trips through the monitor's plumbing")
  func privatePasteboardRoundTrip() throws {
    let pasteboard = NSPasteboard(name: privateName())
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([NSString("hello from the private pasteboard")]))

    let items = try #require(pasteboard.pasteboardItems)
    let outcome = extract(items, bundleID: nil)
    #expect(outcome?.rejection == nil)
    #expect(outcome?.item.contents.count == 1)
    #expect(outcome?.item.vaultBody.contains("hello from the private pasteboard") == true)
    pasteboard.releaseGlobally()
  }

  @Test("A secret written to a real pasteboard is still dropped")
  func secretOnPrivatePasteboardDropped() async throws {
    let pasteboard = NSPasteboard(name: privateName())
    pasteboard.clearContents()
    pasteboard.writeObjects([NSString("sk_live_4eC39HqLyjWDarjtT1zdp7dcABCDEF")])
    let items = try #require(pasteboard.pasteboardItems)
    #expect(extract(items, bundleID: nil)?.rejection == .secretDetected(.stripeKey))
    pasteboard.releaseGlobally()
  }

  /// A name no other process or pasteboard server entry will ever have.
  private func privateName() -> NSPasteboard.Name {
    NSPasteboard.Name("app.copyz.tests.\(UUID().uuidString)")
  }
}