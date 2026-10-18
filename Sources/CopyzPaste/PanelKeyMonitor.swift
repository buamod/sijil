import AppKit
import Foundation

/// Arrow-key navigation while the panel has focus.
///
/// This is a **local** monitor, not a global one. `NSEvent.addLocalMonitorForEvents`
/// needs no Accessibility grant — only the global variant does, and only for key
/// masks — which matters because Quick Mode must work before the user has
/// granted anything beyond the pasteboard.
///
/// The distinction that makes Quick Mode possible at all: our panel is key
/// while the shortcut is held, so local events reach us even though the target
/// app is still the one that will receive the paste.
@MainActor
public final class PanelKeyMonitor {
  public enum Action: Sendable, Equatable {
    case moveSelection(Int)
    case copySelection
    case pasteSelection
    case copySelectionPlain
    case pasteSelectionPlain
    case togglePinSelection
    case deleteSelection
    case dismiss
    case startSearch
  }

  private var monitor: Any?
  private var handler: (@MainActor (Action) -> Void)?

  public init() {}

  deinit {
    MainActor.assumeIsolated { stop() }
  }

  public var isRunning: Bool { monitor != nil }

  /// Begins intercepting panel key events. Only useful while the panel is key.
  public func start(onAction: @escaping @MainActor (Action) -> Void) {
    stop()
    handler = onAction

    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      // `NSEvent` is not `Sendable`, so the mapping works on plain values
      // rather than passing the event across an isolation boundary.
      let action = Self.action(
        forKeyCode: event.keyCode,
        modifiers: event.modifierFlags,
        characters: event.charactersIgnoringModifiers
      )
      guard let action, let self else { return event }
      MainActor.assumeIsolated { self.handler?(action) }
      // Returning nil swallows the event; returning it lets it through.
      return nil
    }
  }

  public func stop() {
    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
    handler = nil
  }

  /// Maps a key press to an action. Deliberately `nonisolated`: the event
  /// monitor closure runs outside actor isolation, and this needs no state, so
  /// keeping it isolated would only force a hop.
  nonisolated static func action(
    forKeyCode keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    characters: String?
  ) -> Action? {
    let flags = modifiers.intersection(.deviceIndependentFlagsMask)
    let command = flags.contains(.command)
    let option = flags.contains(.option)
    let shift = flags.contains(.shift)

    switch keyCode {
    case 125: return .moveSelection(1) // ↓
    case 126: return .moveSelection(-1) // ↑
    case 53: return .dismiss // esc
    case 51, 115: return .deleteSelection // delete, forward delete
    case 36, 76, 71, 48:
      // Return, ⌘M, ⌘E, and tab all commit the selection.
      return command ? .dismiss : .copySelection
    default:
      // ⌘P pins, matching Maccy and Finder muscle memory.
      if command, !shift, !option, characters?.lowercased() == "p" {
        return .togglePinSelection
      }
      return nil
    }
  }
}