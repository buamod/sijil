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
    scheduleTimer()
  }

  public func stop() {
    started = false
    timer?.invalidate()
    timer = nil
    debounceTask?.cancel()
    debounceTask = nil
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
    guard pasteboard.changeCount != lastChangeCount else { return }

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
    lastChangeCount = pasteboard.changeCount

    debounceTask?.cancel()
    debounceTask = Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: configuration.debounceInterval)
      guard !Task.isCancelled else { return }
      handleChange(sourceBundleID: bundleID, sourceAppName: appName)
    }
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