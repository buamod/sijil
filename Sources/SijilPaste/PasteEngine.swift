import AppKit
import Carbon.HIToolbox
import Foundation
import SijilCore
import os

/// Sends a synthetic ⌘V to whichever app was frontmost before our panel opened.
///
/// `CGEvent` posting is the technique every shipping clipboard manager uses.
/// The `AXUIElement` alternative — walking the target's menu bar and pressing
/// Edit ▸ Paste — is more semantically correct but fragile: it breaks under
/// localisation ("Edit"/"Paste" titles change), on apps with no exposed AX tree
/// (Electron, games, canvas-drawn UI), and it cancels any menu the user had
/// open. Notably, `Accessibility` is also categorically incompatible with the
/// App Sandbox, whereas `CGEvent` posting (TCC `PostEvent`) is not.
@MainActor
/// Sends the synthetic ⌘V.
///
/// A protocol so the paste *sequence* can be tested without posting real
/// events. The implementation posts `CGEvent`s, which needs a TCC `PostEvent`
/// grant and would paste into whatever the test machine had focused.
public protocol KeystrokeSending: AnyObject {
  func sendPasteKeystroke()
}

extension KeystrokeSending where Self == CGEventKeystrokeSender {
  @MainActor
  static var cgEvent: CGEventKeystrokeSender { CGEventKeystrokeSender() }
}

/// The real implementation: posts `CGEvent`s.
public final class CGEventKeystrokeSender: KeystrokeSending {
  public init() {}

  public func sendPasteKeystroke() {
    PasteEngine.sendPasteKeystroke()
  }
}

public enum PasteEngine {
  private static let log = Logger(subsystem: "com.buamod.sijil", category: "paste")

  /// Virtual keycode for the physical V key.
  private static let pasteKeyCode = CGKeyCode(kVK_ANSI_V)

  public enum Failure: LocalizedError {
    case accessibilityDenied
    case noTarget
    case writeFailed

    public var errorDescription: String? {
      switch self {
      case .accessibilityDenied:
        "Grant Accessibility access so sijil can paste for you. "
          + "Until then it copies and you press ⌘V."
      case .noTarget:
        "No target application to paste into."
      case .writeFailed:
        "Could not put the item on the clipboard."
      }
    }
  }

  /// Copies `item` to the pasteboard, then pastes it into `target`.
  ///
  /// - Parameter target: the app to paste into, captured *before* our panel
  ///   took focus. Passing the current frontmost app at paste time would hand
  ///   us our own process.
  @discardableResult
  @MainActor
  public static func paste(
    item: ClipItem,
    into target: NSRunningApplication?,
    pasteboard: NSPasteboard = .general,
    plainTextOnly: Bool = false
  ) -> Result<Void, Failure> {
    paste(
      item: item,
      hasTarget: target != nil,
      pasteboard: pasteboard,
      plainTextOnly: plainTextOnly,
      sender: .cgEvent,
      isAccessibilityGranted: { Accessibility.requestIfNeeded() },
      activate: { target?.activate() },
      settle: { seconds in
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
      }
    )
  }

  /// The paste sequence with every side effect injected.
  ///
  /// `paste(...)` needs a real Accessibility grant and a real frontmost app, so
  /// none of the ordering that matters can be exercised through it — refuse
  /// before writing, write before activating, activate before the keystroke.
  ///
  /// The target is reduced to `hasTarget` because that is the only thing the
  /// sequence does with it: it activates, and `NSRunningApplication` cannot be
  /// constructed outside a running app. Keeping it in the signature would make
  /// the whole function untestable for no gain.
  @MainActor
  static func paste(
    item: ClipItem,
    hasTarget: Bool,
    pasteboard: NSPasteboard,
    plainTextOnly: Bool,
    sender: KeystrokeSending,
    isAccessibilityGranted: () -> Bool,
    activate: () -> Void,
    settle: (TimeInterval) -> Void
  ) -> Result<Void, Failure> {
    // Checked before anything else: prompting for Accessibility as a side effect
    // of a paste the user is about to cancel is worse than not trying.
    guard isAccessibilityGranted() else {
      log.error("paste refused: accessibility not granted")
      return .failure(.accessibilityDenied)
    }

    guard hasTarget else { return .failure(.noTarget) }

    // Write first: if the write fails there is no point activating anything, and
    // a failed write must not be reported as "no target", which is a different
    // problem with a different fix.
    guard PasteboardWriter.write(item, to: pasteboard, plainTextOnly: plainTextOnly) else {
      log.error("paste refused: pasteboard write failed")
      return .failure(.writeFailed)
    }

    // `activateIgnoringOtherApps` is deprecated and inert on macOS 14+. A plain
    // activate is the supported path now that focus-stealing prevention exists.
    activate()

    // Give the target a beat to become frontmost, or the keystroke lands while
    // our panel still owns focus.
    settle(0.05)
    sender.sendPasteKeystroke()
    return .success(())
  }

  /// Copies without pasting, for the no-Accessibility fallback.
  @discardableResult
  @MainActor
  public static func copyOnly(
    item: ClipItem,
    pasteboard: NSPasteboard = .general,
    plainTextOnly: Bool = false
  ) -> Bool {
    PasteboardWriter.write(item, to: pasteboard, plainTextOnly: plainTextOnly)
  }

  /// Posts a synthetic ⌘V.
  ///
  /// Every part of this is load-bearing:
  ///
  /// - `CGEventSource(stateID: .combinedSessionState)` carries the modifier
  ///   state as the session perceives it.
  /// - `setLocalEventsFilterDuringSuppressionState` stops our own app from
  ///   seeing and swallowing the synthetic event, while leaving the mouse live.
  /// - The `0x000008` flag bit marks the key as physically down; without it
  ///   apps that inspect that bit ignore the paste.
  /// - The keycode is resolved against the current layout, not hardcoded to
  ///   ANSI, so Dvorak-QWERTY-⌘ and friends work.
  static func sendPasteKeystroke() {
    let cmdFlag = CGEventFlags(
      rawValue: UInt64(cmdKey) | 0x000008
    )
    let keyCode = currentLayoutVirtualKey(for: pasteKeyCode)

    let source = CGEventSource(stateID: .combinedSessionState)
    source?.setLocalEventsFilterDuringSuppressionState(
      [.permitLocalMouseEvents, .permitSystemDefinedEvents],
      state: .eventSuppressionStateSuppressionInterval
    )

    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    down?.flags = cmdFlag
    up?.flags = cmdFlag

    // `.cgSessionEventTap`, not `.cghidEventTap`: session level reaches other
    // apps' sessions and is what the `PostEvent` TCC grant covers.
    down?.post(tap: CGEventTapLocation.cgSessionEventTap)
    up?.post(tap: CGEventTapLocation.cgSessionEventTap)
  }

  /// Translates a QWERTY virtual keycode into the current keyboard layout.
  ///
  /// Needed because ⌘ switches to QWERTY in some layouts (Dvorak-QWERTY-⌘),
  /// so the ANSI code for V is not the code the user's layout expects.
  private static func currentLayoutVirtualKey(for ansiKeyCode: CGKeyCode) -> CGKeyCode {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
      return ansiKeyCode
    }
    guard
      let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return ansiKeyCode }

    let layout = unsafeBitCast(rawLayout, to: CFData.self)
    let count = CFDataGetLength(layout) / MemoryLayout<UCKeyboardLayout>.size
    guard count > 0 else { return ansiKeyCode }

    // `UCKeyTranslate` is imported as a function with an out-parameter rather than
    // as a result type, so the single output slot is declared explicitly and
    // zeroed.
    // The out-parameter is declared `Int` in the imported signature even though
    // it carries a virtual keycode.
    var virtualKeyCode: Int = 0
    let status = CFDataGetBytePtr(layout).withMemoryRebound(
      to: UCKeyboardLayout.self,
      capacity: count
    ) { keyboardLayout in
      UCKeyTranslate(
        keyboardLayout,
        ansiKeyCode,
        UInt16(kUCKeyActionDisplay),
        0,  // no modifiers: we supply ⌘ ourselves
        UInt32(LMGetKbdType()),
        0,
        nil,
        0,
        &virtualKeyCode,
        nil
      )
    }
    guard status == noErr, virtualKeyCode != 0 else { return ansiKeyCode }
    return CGKeyCode(UInt16(virtualKeyCode))
  }
}
