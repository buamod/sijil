import AppKit
import Foundation
import Testing

@testable import SijilCore
@testable import SijilPaste

/// The paste sequence, with every side effect injected.
///
/// `PasteEngine.paste` needs a live Accessibility grant and a real frontmost
/// application, so what is worth testing — the *ordering* — is exactly what
/// cannot be reached through it. These tests assert the order in which the steps
/// happen, which is the part that is easy to get subtly wrong and produces
/// "pasted into the wrong window" reports.
@MainActor
@Suite("Paste engine")
struct PasteEngineTests {
  /// Records what happened, in order.
  private final class Journal: KeystrokeSending {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
    func sendPasteKeystroke() { record("keystroke") }
  }

  private func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("com.buamod.sijil.tests.\(UUID().uuidString)"))
  }

  private func textItem(_ text: String) -> ClipItem {
    ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data(text.utf8))
    ])
  }

  private func run(
    item: ClipItem,
    pasteboard: NSPasteboard,
    hasTarget: Bool = true,
    accessibility: Bool = true,
    journal: Journal,
    onActivate: () -> Void = {}
  ) -> Result<Void, PasteEngine.Failure> {
    PasteEngine.paste(
      item: item,
      hasTarget: hasTarget,
      pasteboard: pasteboard,
      plainTextOnly: false,
      sender: journal,
      isAccessibilityGranted: { accessibility },
      activate: {
        onActivate()
        journal.record("activate")
      },
      settle: { seconds in journal.record("settle:\(seconds)") }
    )
  }

  // MARK: - Ordering

  @Test("The clipboard is written before the target is activated")
  func writesBeforeActivating() {
    let pasteboard = makePasteboard()
    let journal = Journal()

    // The write is observed through the pasteboard's contents at the moment the
    // target is activated, which is the only way to catch an inverted order.
    var contentAtActivate: String?
    let result = run(item: textItem("ordering probe"), pasteboard: pasteboard, journal: journal) {
      contentAtActivate = pasteboard.pasteboardItems?.first?.string(forType: .string)
    }

    #expect((try? result.get()) != nil)
    #expect(contentAtActivate == "ordering probe", "the target was activated before the write")
    pasteboard.releaseGlobally()
  }

  @Test("A successful paste writes, activates, settles, then sends the keystroke")
  func successfulSequence() {
    let pasteboard = makePasteboard()
    let journal = Journal()
    let result = run(item: textItem("hello"), pasteboard: pasteboard, journal: journal)

    #expect((try? result.get()) != nil)
    #expect(journal.events == ["activate", "settle:0.05", "keystroke"])
    #expect(pasteboard.pasteboardItems?.first?.string(forType: .string) == "hello")
    pasteboard.releaseGlobally()
  }

  @Test("The settle window is long enough for the target to take focus")
  func settleWindowIsSufficient() {
    let pasteboard = makePasteboard()
    let journal = Journal()
    _ = run(item: textItem("x"), pasteboard: pasteboard, journal: journal)

    let settle = journal.events.compactMap { event -> TimeInterval? in
      guard event.hasPrefix("settle:") else { return nil }
      return TimeInterval(event.dropFirst("settle:".count))
    }
    #expect(settle.count == 1)
    // Below ~50ms the keystroke lands while our own panel still owns focus.
    #expect((settle.first ?? 0) >= 0.05)
    pasteboard.releaseGlobally()
  }

  @Test("The keystroke is sent exactly once")
  func singleKeystroke() {
    let pasteboard = makePasteboard()
    let journal = Journal()
    _ = run(item: textItem("once"), pasteboard: pasteboard, journal: journal)
    #expect(journal.events.filter { $0 == "keystroke" }.count == 1)
    pasteboard.releaseGlobally()
  }

  // MARK: - Refusal

  @Test("Without Accessibility nothing is written or activated")
  func accessibilityDeniedIsInert() {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    pasteboard.writeObjects([NSString(string: "pre-existing")])

    let journal = Journal()
    let result = run(
      item: textItem("secret"), pasteboard: pasteboard,
      accessibility: false, journal: journal
    )

    guard case .failure(let failure) = result else {
      Issue.record("expected a failure")
      return
    }
    #expect(failure == .accessibilityDenied)
    #expect(journal.events.isEmpty, "nothing may happen after a refusal")
    #expect(pasteboard.pasteboardItems?.first?.string(forType: .string) == "pre-existing")
    pasteboard.releaseGlobally()
  }

  @Test("With no target the clipboard is left alone")
  func noTargetIsInert() {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    pasteboard.writeObjects([NSString(string: "pre-existing")])

    let journal = Journal()
    let result = run(
      item: textItem("replacement"), pasteboard: pasteboard,
      hasTarget: false, journal: journal
    )

    guard case .failure(let failure) = result else {
      Issue.record("expected a failure")
      return
    }
    #expect(failure == .noTarget)
    #expect(journal.events.isEmpty)
    #expect(pasteboard.pasteboardItems?.first?.string(forType: .string) == "pre-existing")
    pasteboard.releaseGlobally()
  }

  @Test("Accessibility is checked before the target is")
  func accessibilityCheckedFirst() {
    // Both are refusals, but prompting for Accessibility when there is nowhere
    // to paste would be a pointless system dialog.
    let pasteboard = makePasteboard()
    let journal = Journal()
    let result = run(
      item: textItem("x"), pasteboard: pasteboard,
      hasTarget: false, accessibility: false, journal: journal
    )
    guard case .failure(let failure) = result else {
      Issue.record("expected a failure")
      return
    }
    #expect(failure == .accessibilityDenied)
    pasteboard.releaseGlobally()
  }

  // MARK: - Copy-only fallback

  @Test("copyOnly writes without needing a target or Accessibility")
  func copyOnlyFallback() {
    let pasteboard = makePasteboard()
    // This is exactly the path used when the grant is missing, so it must not
    // depend on it in any way.
    #expect(PasteEngine.copyOnly(item: textItem("fallback"), pasteboard: pasteboard))
    #expect(pasteboard.pasteboardItems?.first?.string(forType: .string) == "fallback")
    pasteboard.releaseGlobally()
  }

  @Test("plainTextOnly drops rich representations")
  func plainTextOnlyDropsRichTypes() {
    let rich = makePasteboard()
    let item = ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data("plain body".utf8)),
      ClipContent(type: PasteboardType.html.rawValue, value: Data("<b>rich</b>".utf8)),
    ])

    #expect(PasteboardWriter.write(item, to: rich, plainTextOnly: true))
    let types = Set(rich.pasteboardItems?.first?.types.map(\.rawValue) ?? [])
    #expect(!types.contains(PasteboardType.html.rawValue))
    #expect(types.contains(PasteboardType.string.rawValue))
    rich.releaseGlobally()
  }

  @Test("Rich representations survive a normal paste")
  func richTypesSurviveNormalPaste() {
    let rich = makePasteboard()
    let item = ClipItem(contents: [
      ClipContent(type: PasteboardType.string.rawValue, value: Data("plain body".utf8)),
      ClipContent(type: PasteboardType.html.rawValue, value: Data("<b>rich</b>".utf8)),
    ])

    #expect(PasteboardWriter.write(item, to: rich, plainTextOnly: false))
    let types = Set(rich.pasteboardItems?.first?.types.map(\.rawValue) ?? [])
    #expect(types.contains(PasteboardType.html.rawValue))
    rich.releaseGlobally()
  }

  @Test("An image item keeps its binary representation")
  func imageKeepsBinaryType() {
    let board = makePasteboard()
    let image = ClipItem(contents: [
      ClipContent(type: PasteboardType.png.rawValue, value: Data([0x89, 0x50, 0x4E, 0x47]))
    ])
    #expect(PasteboardWriter.write(image, to: board, plainTextOnly: false))
    let types = Set(board.pasteboardItems?.first?.types.map(\.rawValue) ?? [])
    #expect(types.contains(PasteboardType.png.rawValue))
    board.releaseGlobally()
  }

  @Test("Every failure has a message the user can act on")
  func failuresAreActionable() {
    #expect(
      PasteEngine.Failure.accessibilityDenied.errorDescription?.contains("Accessibility") == true
    )
    #expect(PasteEngine.Failure.noTarget.errorDescription?.isEmpty == false)
    #expect(PasteEngine.Failure.writeFailed.errorDescription?.isEmpty == false)
  }
}
