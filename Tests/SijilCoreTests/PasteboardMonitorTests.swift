import AppKit
import Foundation
import Testing

@testable import SijilCore

/// The monitor's polling state machine, driven directly against a private
/// pasteboard.
///
/// A `Timer` on `RunLoop.main` cannot be stepped deterministically, which is why
/// `poll()` exists as a separate method. Everything here uses a uniquely-named
/// `NSPasteboard`, so no TCC grant is needed and the user's real clipboard is
/// never touched.
@MainActor
@Suite("Pasteboard monitor")
struct PasteboardMonitorTests {
  private func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("com.buamod.sijil.tests.\(UUID().uuidString)"))
  }

  private func makeMonitor(
    _ pasteboard: NSPasteboard,
    rules: CaptureRules = CaptureRules()
  ) -> PasteboardMonitor {
    PasteboardMonitor(pasteboard: pasteboard, rules: rules)
  }

  @Test("An unchanged pasteboard produces nothing")
  func noChangeNoEvent() {
    let pasteboard = makePasteboard()
    let monitor = makeMonitor(pasteboard)
    var events = 0
    monitor.onEvent = { _ in events += 1 }

    #expect(monitor.poll() == false)
    monitor.flushPendingChange()
    #expect(events == 0)
    pasteboard.releaseGlobally()
  }

  @Test("A change is captured exactly once")
  func changeCapturedOnce() {
    let pasteboard = makePasteboard()
    let monitor = makeMonitor(pasteboard)
    var captured: [ClipItem] = []
    monitor.onEvent = { event in
      if case .captured(let item) = event { captured.append(item) }
    }

    pasteboard.clearContents()
    pasteboard.writeObjects([NSString("first capture")])

    #expect(monitor.poll() == true, "changeCount moved")
    monitor.flushPendingChange()
    // The baseline is updated by poll, so a second pass must not re-report.
    #expect(monitor.poll() == false)
    monitor.flushPendingChange()

    #expect(captured.count == 1)
    #expect(captured.first?.vaultBody.contains("first capture") == true)
    pasteboard.releaseGlobally()
  }

  @Test("Consecutive changes are all captured")
  func consecutiveChanges() {
    let pasteboard = makePasteboard()
    let monitor = makeMonitor(pasteboard)
    var captured: [String] = []
    monitor.onEvent = { event in
      if case .captured(let item) = event { captured.append(item.vaultBody) }
    }

    for text in ["one", "two", "three"] {
      pasteboard.clearContents()
      pasteboard.writeObjects([NSString(string: text)])
      #expect(monitor.poll())
      monitor.flushPendingChange()
    }

    #expect(captured.count == 3)
    #expect(captured.last?.contains("three") == true)
    pasteboard.releaseGlobally()
  }

  @Test("skipNextCopy drops exactly one copy")
  func skipNextCopy() {
    let pasteboard = makePasteboard()
    let monitor = makeMonitor(pasteboard)
    var captured = 0
    monitor.onEvent = { event in
      if case .captured = event { captured += 1 }
    }

    monitor.skipNextCopy()

    pasteboard.clearContents()
    pasteboard.writeObjects([NSString("skip me")])
    monitor.poll()
    monitor.flushPendingChange()

    pasteboard.clearContents()
    pasteboard.writeObjects([NSString("keep me")])
    monitor.poll()
    monitor.flushPendingChange()

    #expect(captured == 1, "the second copy should have been kept")
    pasteboard.releaseGlobally()
  }

  @Test("The self-write marker stops sijil recording its own paste")
  func selfWriteIsIgnored() {
    let pasteboard = makePasteboard()
    let monitor = makeMonitor(pasteboard)
    var captured = 0
    monitor.onEvent = { event in
      if case .captured = event { captured += 1 }
    }

    let item = NSPasteboardItem()
    item.setString("sijil wrote this", forType: .string)
    item.setData(
      Data("1".utf8), forType: NSPasteboard.PasteboardType(PasteboardType.selfMarker.rawValue))
    pasteboard.clearContents()
    pasteboard.writeObjects([item])

    monitor.poll()
    monitor.flushPendingChange()
    #expect(captured == 0, "sijil must not record its own synthetic paste")

    // And the marker must not consume the skip flag, or the user's next real
    // copy would be swallowed.
    monitor.poll()
    monitor.flushPendingChange()
    pasteboard.clearContents()
    pasteboard.writeObjects([NSString("a real copy")])
    monitor.poll()
    monitor.flushPendingChange()
    #expect(captured == 1)
    pasteboard.releaseGlobally()
  }

  @Test("noteOwnWrite re-baselines so the restore is not captured")
  func noteOwnWriteRebaselines() {
    let pasteboard = makePasteboard()
    let monitor = makeMonitor(pasteboard)
    var captured = 0
    monitor.onEvent = { event in
      if case .captured = event { captured += 1 }
    }

    pasteboard.clearContents()
    pasteboard.writeObjects([NSString("restored by sijil")])
    monitor.noteOwnWrite()

    #expect(monitor.poll() == false, "the baseline should already cover this")
    monitor.flushPendingChange()
    #expect(captured == 0)
    pasteboard.releaseGlobally()
  }

  @Test("A rejected copy is reported as a rejection, not a capture")
  func rejectedIsNotCaptured() {
    let pasteboard = makePasteboard()
    var rules = CaptureRules()
    rules.isCapturing = false
    let monitor = makeMonitor(pasteboard, rules: rules)

    var rejections: [CaptureRules.Rejection] = []
    var captured = 0
    monitor.onEvent = { event in
      switch event {
      case .captured: captured += 1
      case .rejected(let reason): rejections.append(reason)
      }
    }

    pasteboard.clearContents()
    pasteboard.writeObjects([NSString("while paused")])
    monitor.poll()
    monitor.flushPendingChange()

    #expect(captured == 0)
    #expect(rejections == [.paused])
    pasteboard.releaseGlobally()
  }

  @Test("Changing rules recompiles the ignore patterns")
  func ruleChangesTakeEffect() {
    let pasteboard = makePasteboard()
    let monitor = makeMonitor(pasteboard)
    var captured = 0
    monitor.onEvent = { event in
      if case .captured = event { captured += 1 }
    }

    pasteboard.clearContents()
    pasteboard.writeObjects([NSString("SECRET-1")])
    monitor.poll()
    monitor.flushPendingChange()
    #expect(captured == 1)

    var rules = CaptureRules()
    rules.ignoredPatterns = ["^SECRET-"]
    monitor.rules = rules

    pasteboard.clearContents()
    pasteboard.writeObjects([NSString("SECRET-2")])
    monitor.poll()
    monitor.flushPendingChange()
    #expect(captured == 1, "the new pattern must apply without a restart")
    pasteboard.releaseGlobally()
  }

  @Test("Toggling secret detection applies without a restart")
  func secretDetectionIsLive() {
    let pasteboard = makePasteboard()
    let monitor = makeMonitor(pasteboard)
    var captured = 0
    var rejected: [CaptureRules.Rejection] = []
    monitor.onEvent = { event in
      switch event {
      case .captured: captured += 1
      case .rejected(let reason): rejected.append(reason)
      }
    }

    pasteboard.clearContents()
    pasteboard.writeObjects([NSString("AKIAIOSFODNN7EXAMPLE")])
    monitor.poll()
    monitor.flushPendingChange()
    #expect(captured == 0)
    #expect(rejected.count == 1)

    var permissive = CaptureRules()
    permissive.detectsSecrets = false
    monitor.rules = permissive

    pasteboard.clearContents()
    pasteboard.writeObjects([NSString("AKIAIOSFODNN7EXAMPLE")])
    monitor.poll()
    monitor.flushPendingChange()
    #expect(captured == 1, "turning detection off must take effect immediately")
    pasteboard.releaseGlobally()
  }

  @Test("An empty pasteboard produces no event")
  func emptyPasteboardIsSilent() {
    let pasteboard = makePasteboard()
    let monitor = makeMonitor(pasteboard)
    var events = 0
    monitor.onEvent = { _ in events += 1 }

    pasteboard.clearContents()
    monitor.poll()
    monitor.flushPendingChange()
    #expect(events == 0)
    pasteboard.releaseGlobally()
  }

  @Test("stop then start does not double-report")
  func restartDoesNotDuplicate() {
    let pasteboard = makePasteboard()
    let monitor = makeMonitor(pasteboard)
    var captured = 0
    monitor.onEvent = { event in
      if case .captured = event { captured += 1 }
    }

    monitor.start()
    monitor.start()  // idempotent
    monitor.stop()

    pasteboard.clearContents()
    pasteboard.writeObjects([NSString("after restart")])
    monitor.poll()
    monitor.flushPendingChange()
    #expect(captured == 1)
    pasteboard.releaseGlobally()
  }

  @Test("Starting re-baselines, so pre-launch copies are not captured")
  func startDoesNotCaptureBacklog() {
    let pasteboard = makePasteboard()
    pasteboard.clearContents()
    pasteboard.writeObjects([NSString("copied before launch")])

    let monitor = makeMonitor(pasteboard)
    var captured = 0
    monitor.onEvent = { event in
      if case .captured = event { captured += 1 }
    }

    // Initialised against the old count, so it *would* see the change — but
    // start() re-baselines, which is the point.
    monitor.start()
    #expect(monitor.poll() == false)
    monitor.flushPendingChange()
    #expect(captured == 0)

    // A genuinely new copy after start is still seen.
    pasteboard.clearContents()
    pasteboard.writeObjects([NSString("after launch")])
    monitor.poll()
    monitor.flushPendingChange()
    #expect(captured == 1)
    monitor.stop()
    pasteboard.releaseGlobally()
  }

  @Test("Updating the configuration keeps monitoring working")
  func configurationUpdate() {
    let pasteboard = makePasteboard()
    let monitor = makeMonitor(pasteboard)
    monitor.updateConfiguration(.init(pollInterval: 1.0, debounceInterval: .milliseconds(1)))
    #expect(monitor.configuration.pollInterval == 1.0)

    var captured = 0
    monitor.onEvent = { event in
      if case .captured = event { captured += 1 }
    }
    pasteboard.clearContents()
    pasteboard.writeObjects([NSString("still working")])
    monitor.poll()
    monitor.flushPendingChange()
    #expect(captured == 1)
    pasteboard.releaseGlobally()
  }
}
