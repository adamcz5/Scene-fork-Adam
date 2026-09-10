import AppKit
import SceneCore

/// Drives the filtered ⌥Tab / ⌥⇧Tab app switcher (V0.9): press-and-hold ⌥Tab
/// to open a HUD over just the apps configured in Settings → Interaction →
/// App Switcher, tap Tab again (while Option stays held) to advance, release
/// Option to activate whichever app is highlighted.
///
/// Deliberately independent of `Coordinator`'s `HotkeyManager` — that one is
/// gated behind Accessibility permission (it manipulates window frames via
/// AX); this controller only calls `NSRunningApplication.activate()`, which
/// needs no special permission, so it should work even for a user who hasn't
/// granted AX yet.
@MainActor
final class AppSwitcherController {
    private let hotkeyManager = HotkeyManager()
    private let hud: AppSwitcherHUDWindowController
    private var config: AppSwitcherConfig = .default

    /// Non-empty and `isActive` only while Option is physically held down
    /// after a ⌥Tab/⌥⇧Tab fire — cleared the instant Option is released
    /// (`commit()`) or Esc cancels the session.
    private var candidates: [String] = []
    private var selectedIndex = 0
    private var isActive = false

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?

    private static let forwardUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private static let reverseUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    /// Carbon virtual keycode for Escape — matches `DragSwapController`'s own
    /// hardcoded 53 (`kVK_Escape` isn't in the small subset of `Carbon.HIToolbox`
    /// symbols re-exposed via `HotkeyModifiers`, so this mirrors the existing
    /// convention rather than adding a Carbon import just for one constant).
    private static let escapeKeyCode: UInt16 = 53

    // No default value for `hud` — a default parameter expression is type-
    // checked as if nonisolated regardless of the enclosing type's actor,
    // and `AppSwitcherHUDWindowController.init()` is `@MainActor`-isolated
    // (it touches `NSPanel`), so `AppSwitcherHUDWindowController()` as a
    // default value fails to compile even though every real call site is
    // already on MainActor. Construct it explicitly instead.
    init(hud: AppSwitcherHUDWindowController) {
        self.hud = hud
    }

    deinit {
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        if let globalKeyDownMonitor { NSEvent.removeMonitor(globalKeyDownMonitor) }
        if let localKeyDownMonitor { NSEvent.removeMonitor(localKeyDownMonitor) }
    }

    /// Re-registers (or tears down) the ⌥Tab/⌥⇧Tab hotkeys to match the
    /// latest Settings. Safe to call repeatedly — call on launch and on
    /// every `SettingsStore.onChange` fire.
    func configure(_ config: AppSwitcherConfig) {
        self.config = config
        hotkeyManager.unregisterAll()
        guard config.enabled, !config.bundleIDs.isEmpty else {
            finish()
            return
        }
        hotkeyManager.register(
            uuid: Self.forwardUUID,
            keyCode: HotkeyModifiers.tabKeyCode,
            modifiers: HotkeyModifiers.optionOnly,
            handler: { [weak self] in self?.trigger(reverse: false) }
        )
        hotkeyManager.register(
            uuid: Self.reverseUUID,
            keyCode: HotkeyModifiers.tabKeyCode,
            modifiers: HotkeyModifiers.optionShift,
            handler: { [weak self] in self?.trigger(reverse: true) }
        )
    }

    private func trigger(reverse: Bool) {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if !isActive {
            candidates = AppSwitcherLogic.candidates(config: config, runningBundleIDs: running)
            guard !candidates.isEmpty else { return }
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            selectedIndex = AppSwitcherLogic.startIndex(candidates: candidates, frontmostBundleID: frontmost)
            isActive = true
            installMonitors()
        } else {
            guard !candidates.isEmpty else { return }
            selectedIndex = AppSwitcherLogic.advance(index: selectedIndex, count: candidates.count, reverse: reverse)
        }
        hud.show(candidates: candidates, selectedIndex: selectedIndex)
    }

    // MARK: - Option-release commit / Esc cancel

    private func installMonitors() {
        guard globalFlagsMonitor == nil else { return }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        // Global monitors only see events destined for *other* apps (same
        // caveat `WorkspacePickerWindowController` documents for its click
        // monitors) — the HUD panel itself belongs to this app, so a local
        // monitor covers Option being released while the HUD happens to be
        // the event's nominal destination.
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
            return event
        }
    }

    private func removeMonitors() {
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        if let globalKeyDownMonitor { NSEvent.removeMonitor(globalKeyDownMonitor) }
        if let localKeyDownMonitor { NSEvent.removeMonitor(localKeyDownMonitor) }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        globalKeyDownMonitor = nil
        localKeyDownMonitor = nil
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard isActive, !event.modifierFlags.contains(.option) else { return }
        commit()
    }

    private func handleKeyDown(_ event: NSEvent) {
        guard isActive, event.keyCode == Self.escapeKeyCode else { return }
        finish()
    }

    private func commit() {
        defer { finish() }
        guard candidates.indices.contains(selectedIndex) else { return }
        let bundleID = candidates[selectedIndex]
        NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID })?
            .activate()
    }

    private func finish() {
        isActive = false
        candidates = []
        selectedIndex = 0
        removeMonitors()
        hud.hide()
    }
}
