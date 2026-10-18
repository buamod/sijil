import AppKit
import Carbon.HIToolbox
import CopyzCore
import Foundation
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
public enum PasteEngine {
  private static let log = Logger(subsystem: "app.copyz", category: "paste")

  /// Virtual keycode for the physical V key.
  private static let pasteKeyCode = CGKeyCode(kVK_ANSI_V)

  public enum Failure: LocalizedError {
    case accessibilityDenied
    case noTarget

    public var errorDescription: String? {
      switch self {
      case .accessibilityDenied:
        "Grant Accessibility access so copyz can paste for you. "
          + "Until then it copies and you press ⌘V."
      case .noTarget:
        "No target application to paste into."
      }
    }
  }

  /// Copies `item` to the pasteboard, then pastes it into `target`.
  ///
  /// - Parameter target: the app to paste into, captured *before* our panel
  ///   took focus. Passing the current frontmost app at paste time would hand
  ///   us our own process.
  @discardableResult
  public static func paste(
    item: ClipItem,
    into target: NSRunningApplication?,
    pasteboard: NSPasteboard = .general,
    plainTextOnly: Bool = false
  ) -> Result<Void, Failure> {
    guard Accessibility.requestIfNeeded() else {
      log.error("paste refused: accessibility not granted")
      return .failure(.accessibilityDenied)
    }

    guard let target else { return .failure(.noTarget) }

    // Write first: if the write fails there is no point reactivating anything.
    guard PasteboardWriter.write(item, to: pasteboard, plainTextOnly: plainTextOnly) else {
      return .failure(.noTarget)
    }

    // `activateIgnoringOtherApps` is deprecated and inert on macOS 14+. A plain
    // activate is the supported path now that focus-stealing prevention exists.
    target.activate()

    // Give the target a beat to become frontmost, or the keystroke lands while
    // our panel still owns focus.
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    sendPasteKeystroke()
    return .success(())
  }

  /// Copies without pasting, for the no-Accessibility fallback.
  @discardableResult
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
        0, // no modifiers: we supply ⌘ ourselves
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