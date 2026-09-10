import Carbon.HIToolbox
import Foundation
import os

public final class HotkeyManager {
    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private let log = Logger(subsystem: "com.scene.core", category: "hotkey")

    /// Process-wide, not per-instance: as of V0.9, more than one `HotkeyManager`
    /// can be alive at once (`Coordinator`'s and `AppSwitcherController`'s,
    /// deliberately independent — see that type's doc comment). All installed
    /// instances' Carbon event handlers sit on the same `GetApplicationEventTarget()`
    /// and each dispatches purely on `EventHotKeyID.id` (see below), so IDs must
    /// never collide across instances — a per-instance counter starting at 1
    /// would let two different instances register the SAME id for two
    /// completely different physical hotkeys, causing one instance to
    /// spuriously fire its handler when the OTHER instance's hotkey is pressed.
    private static var nextID: UInt32 = 1

    public init() {}

    public func register(
        uuid: UUID,
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping () -> Void
    ) {
        ensureEventHandlerInstalled()

        let id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: fourCharCode("SCNE"), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)

        guard status == noErr, let ref else {
            log.error("RegisterEventHotKey failed for \(uuid.uuidString, privacy: .public) status=\(status)")
            return
        }

        refs.append(ref)
        handlers[id] = handler
    }

    public func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }

    private func ensureEventHandlerInstalled() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData = userData, let event = event else { return OSStatus(eventNotHandledErr) }
                var hkID = EventHotKeyID()
                let getStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if getStatus != noErr { return getStatus }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                // Returning `eventNotHandledErr` when this instance doesn't own
                // `hkID.id` — rather than unconditionally `noErr` — matters as
                // soon as more than one `HotkeyManager` instance is alive
                // (V0.9: `AppSwitcherController` owns a separate one from
                // `Coordinator`'s, deliberately, so it isn't gated behind AX
                // permission). Multiple instances each call `InstallEventHandler`
                // on the same `GetApplicationEventTarget()`, forming a handler
                // chain; unconditional `noErr` would let whichever installed
                // last swallow *every* hotkey-pressed event system-wide,
                // silently breaking every other instance's hotkeys.
                guard let handler = manager.handlers[hkID.id] else {
                    return OSStatus(eventNotHandledErr)
                }
                handler()
                return noErr
            },
            1,
            &spec,
            selfPtr,
            &eventHandler
        )
    }
}

private func fourCharCode(_ s: String) -> UInt32 {
    var result: UInt32 = 0
    for ch in s.utf8.prefix(4) {
        result = (result << 8) | UInt32(ch)
    }
    return result
}

public enum HotkeyModifiers {
    public static let cmdShift: UInt32 = UInt32(cmdKey | shiftKey)
    /// ⌥Tab — the filtered app switcher's forward-cycle chord.
    public static let optionOnly: UInt32 = UInt32(optionKey)
    /// ⌥⇧Tab — the filtered app switcher's reverse-cycle chord.
    public static let optionShift: UInt32 = UInt32(optionKey | shiftKey)
    /// Carbon virtual keycode for Tab (`kVK_Tab` from Carbon.HIToolbox,
    /// re-exposed here so `AppSwitcherController` doesn't need its own Carbon
    /// import). The app switcher — unlike every other hotkey in Scene —
    /// hardcodes its trigger key rather than letting the user record an
    /// arbitrary chord, matching the fixed ⌥Tab / ⌥⇧Tab convention set by
    /// HopTab/AltTab-style switchers.
    public static let tabKeyCode: UInt32 = UInt32(kVK_Tab)
}
