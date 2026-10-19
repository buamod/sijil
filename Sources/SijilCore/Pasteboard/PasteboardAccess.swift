import AppKit
import Foundation

/// Forward-compatibility shim for the macOS 15.4 pasteboard privacy model.
///
/// `NSPasteboard.accessBehavior` and the "Paste from Other Apps" TCC pane are
/// inert through macOS 26. macOS 27 removed the developer-preview default and
/// enforcement is turning on — apps that never read `accessBehavior` are
/// reported to be blocked outright. Handling it costs a few lines now versus a
/// dead feature later, so we read it from the first launch.
///
/// Note that user-initiated paste-related access is *always* allowed, so this
/// only ever gates our background polling.
/// Availability-neutral so callers on older OS versions can still name it.
public enum PasteboardAccessState: Sendable, Equatable {
  /// No restriction on this OS version.
  case unrestricted
  /// Reads will prompt the user; they must approve once.
  case requiresApproval
  /// Reads will be refused outright.
  case denied
}

@available(macOS 15.4, *)
public enum PasteboardAccess {
  public typealias State = PasteboardAccessState

  public static var state: State {
    switch NSPasteboard.general.accessBehavior {
    case .alwaysAllow: .unrestricted
    case .alwaysDeny: .denied
    case .ask, .default: .requiresApproval
    @unknown default: .requiresApproval
    }
  }

  /// Deep link to the relevant System Settings pane. The Tahoe path differs
  /// from the Sequoia one; both are attempted by the caller.
  public static var settingsDeepLink: URL? {
    let candidates = [
      "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard",
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard",
    ]
    return candidates.compactMap(URL.init(string:)).first
  }
}

public enum PasteboardAccessCompat {
  /// `nil` on OS versions predating the privacy model.
  public static var state: PasteboardAccessState? {
    if #available(macOS 15.4, *) { PasteboardAccess.state } else { nil }
  }
}
