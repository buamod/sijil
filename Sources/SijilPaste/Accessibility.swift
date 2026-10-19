import AppKit
import ApplicationServices
import Foundation
import os

/// Accessibility authorisation, needed to synthesise a paste into whatever app
/// the user was last using.
///
/// The user is only prompted once; until they grant it, the app degrades to
/// "copy to clipboard and show a HUD" rather than failing outright.
public enum Accessibility {
  private static let log = Logger(subsystem: "com.buamod.sijil", category: "accessibility")

  public static var isTrusted: Bool {
    AXIsProcessTrusted()
  }

  /// Prompts if needed. Returns whether access is granted *now* — the user may
  /// still be looking at the system dialog, and macOS historically requires a
  /// relaunch before the new grant applies.
  @discardableResult
  public static func requestIfNeeded() -> Bool {
    guard !isTrusted else { return true }
    // The key is a plain string constant, so spell it out rather than reading the
    // imported mutable global `kAXTrustedCheckOptionPrompt`, which Swift 6
    // treats as shared mutable state.
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  /// Opens the Accessibility pane. The grant only takes effect after a relaunch,
  /// which we surface in the UI rather than silently leaving a dead button.
  public static func openSettings() {
    let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
    if let url { NSWorkspace.shared.open(url) }
  }

  /// Logs a one-shot notice so we can tell from the log whether a relaunch is
  /// still outstanding.
  public static func logIfPendingRelaunch() {
    guard isTrusted else {
      log.error("accessibility denied; paste will fall back to copy-only")
      return
    }
    log.debug("accessibility granted")
  }
}
