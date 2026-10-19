import AppKit
import Foundation

/// Polls the system pasteboard for changes.
///
/// There is no push API, notification, KVO property, or Combine publisher for
/// `NSPasteboard` — every shipping clipboard manager polls `changeCount`. The
/// interval is tuned to avoid *missing copies*, not to save CPU: a user can
/// copy, switch apps, paste, switch back, and copy again inside a second, and
/// anything slower than that gap loses the first item permanently.
@MainActor
public final class PasteboardMonitor {
  public struct Configuration: Sendable, Equatable {
    /// Poll cadence. 0.4s covers the copy-switch-paste-switch-copy loop.
    public var pollInterval: TimeInterval = 0.4
    /// Apps that clear then write bump `changeCount` twice, so a read taken
    /// immediately can observe the empty intermediate state.
    public var debounceInterval: Duration = .milliseconds(40)

    public init(pollInterval: TimeInterval = 0.4, debounceInterval: Duration = .milliseconds(40)) {
      self.pollInterval = pollInterval
      self.debounceInterval = debounceInterval
    }
  }

  public enum Event: Sendable {
    case captured(ClipItem)
    case rejected(CaptureRules.Rejection)
  }

  private let pasteboard: NSPasteboard
  private var lastChangeCount: Int
  private var timer: Timer?
  private var debounceTask: Task<Void, Never>?
  private var patterns: CompiledPatterns
  private var _rules: CaptureRules
  /// Drop the very next copy regardless of rules ("ignore next copy").
  private var isSkippingNextCopy = false
  private var started = false

  public var configuration: Configuration
  public var onEvent: (@MainActor (Event) -> Void)?

  public var rules: CaptureRules {
    get { _rules }
    set {
      _rules = newValue
      patterns = CompiledPatterns(newValue.ignoredPatterns)
    }
  }

  public init(
    pasteboard: NSPasteboard = .general,
    configuration: Configuration = Configuration(),
    rules: CaptureRules = CaptureRules()
  ) {
    self.pasteboard = pasteboard
    self.configuration = configuration
    self._rules = rules
    self.patterns = CompiledPatterns(rules.ignoredPatterns)
    self.lastChangeCount = pasteboard.changeCount
  }

  // MARK: - Lifecycle

  public func start() {
    guard !started else { return }
    started = true
    // Re-baseline so anything copied before launch is not recorded on start.
    lastChangeCount = pasteboard.changeCount
    pendingSource = nil
    scheduleTimer()
  }

  public func stop() {
    started = false
    timer?.invalidate()
    timer = nil
    debounceTask?.cancel()
    debounceTask = nil
    // A change observed but not yet read must not survive the stop, or it
    // would be captured on the next start long after the fact.
    pendingSource = nil
  }

  public func updateConfiguration(_ configuration: Configuration) {
    self.configuration = configuration
    guard started else { return }
    timer?.invalidate()
    scheduleTimer()
  }

  /// Skip the next observed copy without disturbing any other rules.
  public func skipNextCopy() {
    isSkippingNextCopy = true
  }

  /// Called by `PasteboardWriter` after we write, so we do not record our own
  /// restore as a fresh copy.
  public func noteOwnWrite() {
    lastChangeCount = pasteboard.changeCount
    debounceTask?.cancel()
    debounceTask = nil
    // Our own write is not a change to capture, so drop any pending read of it.
    pendingSource = nil
  }

  private func scheduleTimer() {
    let timer = Timer(
      timeInterval: configuration.pollInterval,
      target: self,
      selector: #selector(tick),
      userInfo: nil,
      repeats: true
    )
    // Lets the system coalesce wakeups with other work; this is what actually
    // matters for battery life, far more than the cost of reading the count.
    timer.tolerance = configuration.pollInterval * 0.25
    // `.common` so polling continues during menu and scroll tracking.
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  // MARK: - Polling

  @objc
  private func tick() {
    poll()
  }

  /// Metadata for a change that has been observed but not yet read.
  ///
  /// Held explicitly so a pasteboard read can only happen in response to an
  /// observed `changeCount` movement. Reading on any other trigger risks
  /// capturing whatever happens to be on the pasteboard at that moment, which is
  /// a copy the monitor never actually saw arrive.
  private var pendingSource: (bundleID: String?, appName: String?)?

  /// One poll: reads `changeCount` and, if it moved, schedules a debounced read.
  ///
  /// Split out from the timer callback so it can be driven directly by tests
  /// against a private pasteboard. A `Timer` on `RunLoop.main` cannot be driven
  /// deterministically, and this method is where all the interesting state
  /// transitions live.
  @discardableResult
  func poll() -> Bool {
    let current = pasteboard.changeCount
    guard current != lastChangeCount else { return false }

    // Capture the source app *now*, while it is still frontmost. By the time
    // the debounce elapses the app may have changed — and once our own panel
    // takes focus, `frontmostApplication` reports us.
    //
    // There is no public API for "which app wrote the pasteboard", so this is
    // necessarily a heuristic. It is stored as advisory metadata only; access
    // decisions key off the pasteboard privacy markers, which are authoritative.
    let sourceApp = NSWorkspace.shared.frontmostApplication
    let bundleID = sourceApp?.bundleIdentifier
    let appName = sourceApp?.localizedName
    lastChangeCount = current

    pendingSource = (bundleID, appName)
    debounceTask?.cancel()
    debounceTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: self.configuration.debounceInterval)
      guard !Task.isCancelled else { return }
      self.flushPendingChange()
    }
    return true
  }

  /// Reads the pasteboard if, and only if, a change is pending.
  ///
  /// Called by the debounce task once the settle window has passed, and directly
  /// by tests. A no-op when nothing is pending, so a stray call cannot read the
  /// pasteboard and capture a copy that was never observed arriving.
  internal func flushPendingChange() {
    guard let source = pendingSource else { return }
    pendingSource = nil
    handleChange(sourceBundleID: source.bundleID, sourceAppName: source.appName)
  }

  private func handleChange(sourceBundleID: String?, sourceAppName: String?) {
    // Our own write. The stamped marker type is what makes this reliable —
    // comparing changeCounts alone races with unrelated copies.
    if pasteboard.pasteboardItems?.contains(where: { $0.types.contains(.selfMarker) }) == true {
      return
    }

    if isSkippingNextCopy {
      isSkippingNextCopy = false
      return
    }

    guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else { return }

    let outcome = PasteboardExtractor.makeItem(
      from: pasteboardItems,
      sourceBundleID: sourceBundleID,
      sourceAppName: sourceAppName,
      rules: rules,
      patterns: patterns
    )

    guard let outcome else { return }

    if let rejection = outcome.rejection {
      onEvent?(.rejected(rejection))
      return
    }
    guard !outcome.item.contents.isEmpty else { return }
    onEvent?(.captured(outcome.item))
  }
}

private extension NSPasteboard.PasteboardType {
  static let selfMarker = NSPasteboard.PasteboardType(PasteboardType.selfMarker.rawValue)
}
