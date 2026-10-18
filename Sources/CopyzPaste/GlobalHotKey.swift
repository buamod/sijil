import Carbon.HIToolbox
import Foundation

/// Global hotkey registration.
///
/// Carbon's `RegisterEventHotKey` is the only public global-hotkey API that
/// requires **no** TCC prompt. That matters twice over for a clipboard manager:
/// the app does not need Accessibility for the hotkey alone, and the key still
/// fires while our own panel has focus — which is what makes
/// hold-to-navigate-quick-mode possible.
///
/// Carbon is nominally "frozen" but `HIToolbox/Events.h` is stable, and Alfred,
/// Raycast, VS Code and Electron all ship Carbon hotkeys today.
@MainActor
public final class GlobalHotKey {
  public struct Binding: Sendable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var displayString: String

    public init(keyCode: UInt32, modifiers: UInt32, displayString: String) {
      self.keyCode = keyCode
      self.modifiers = modifiers
      self.displayString = displayString
    }
  }

  public enum RegistrationError: LocalizedError, Equatable {
    case alreadyRegistered
    case osStatus(OSStatus)

    public var errorDescription: String? {
      switch self {
      case .alreadyRegistered:
        "That shortcut is already in use by copyz."
      case .osStatus(let status):
        "Could not register the shortcut (OSStatus \(status)). It may be claimed "
          + "by the system or another app."
      }
    }
  }

  private var hotKeyRef: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?
  private var pressHandlerRef: EventHandlerRef?
  private var pressHandler: (@MainActor () -> Void)?
  private var releaseHandler: (@MainActor () -> Void)?

  public private(set) var binding: Binding?

  public init() {}

  deinit {
    // Main-actor isolated; on teardown we are already back on the main actor.
    MainActor.assumeIsolated { unregister() }
  }

  public var isRegistered: Bool { hotKeyRef != nil }

  public func register(
    binding newBinding: Binding,
    onPress: @escaping @MainActor () -> Void,
    onRelease: @escaping @MainActor () -> Void = {}
  ) throws {
    unregister()
    pressHandler = onPress
    releaseHandler = onRelease

    var kinds = [EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )]
    var releaseKind = [EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyReleased)
    )]

    let status = InstallEventHandler(
      GetEventDispatcherTarget(),
      // `EventRef` is an opaque pointer with no Swift-side accessors, so pressed and
    // released are told apart by installing one handler per event kind rather
    // than by inspecting the event at runtime.
    { _, event, userData in
      guard let event, let userData else { return OSStatus(noErr) }
      var hotKeyID = EventHotKeyID()
      let result = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
      )
      guard result == noErr, hotKeyID.signature == GlobalHotKey.signature else {
        return OSStatus(eventNotHandledErr)
      }

      let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
      MainActor.assumeIsolated { owner.pressHandler?() }
      return OSStatus(noErr)
    },
    2,
    &kinds,
    Unmanaged.passUnretained(self).toOpaque(),
    &pressHandlerRef
    )

    // Second handler for release, which is what quick mode needs in order to
    // commit the highlighted item when the user lets go of the shortcut.
    let releaseStatus = InstallEventHandler(
      GetEventDispatcherTarget(),
      { _, event, userData in
        guard let event, let userData else { return OSStatus(noErr) }
        var hotKeyID = EventHotKeyID()
        let result = GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &hotKeyID
        )
        guard result == noErr, hotKeyID.signature == GlobalHotKey.signature else {
          return OSStatus(eventNotHandledErr)
        }
        let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated { owner.releaseHandler?() }
        return OSStatus(noErr)
      },
      1,
      &releaseKind,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandler
    )
    guard releaseStatus == noErr else {
      if let pressHandlerRef { RemoveEventHandler(pressHandlerRef) }
      eventHandler = nil
      pressHandler = nil
      releaseHandler = nil
      throw RegistrationError.osStatus(releaseStatus)
    }
    guard status == noErr else {
      eventHandler = nil
      pressHandler = nil
      releaseHandler = nil
      throw RegistrationError.osStatus(status)
    }

    let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
    var reference: EventHotKeyRef?
    let registerStatus = RegisterEventHotKey(
      newBinding.keyCode,
      newBinding.modifiers,
      hotKeyID,
      GetEventDispatcherTarget(),
      0,
      &reference
    )
    guard registerStatus == noErr, let reference else {
      unregister()
      // Carbon permits exactly one registration per key combination, so a
      // repeat attempt with the same combo fails here rather than stealing it.
      throw RegistrationError.alreadyRegistered
    }

    hotKeyRef = reference
    binding = newBinding
  }

  public func unregister() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    if let pressHandlerRef {
      RemoveEventHandler(pressHandlerRef)
      self.pressHandlerRef = nil
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      self.eventHandler = nil
    }
    binding = nil
    pressHandler = nil
    releaseHandler = nil
  }

  /// 'CZYZ'
  private static let signature: OSType = 0x43_5A_59_5A
}