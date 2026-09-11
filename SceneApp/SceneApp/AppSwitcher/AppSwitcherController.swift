import AppKit
import CoreGraphics
import SceneCore

/// Drives the filtered ⌥Tab / ⌥⇧Tab app switcher (V0.9): press-and-hold ⌥Tab
/// to open a HUD over just the apps configured in Settings → Interaction →
/// App Switcher, tap Tab again (while Option stays held) to advance, release
/// Option to activate whichever app is highlighted. For an app with more than
/// one window open, ⌥↓/⌥↑ (also while Option stays held) drills into a
/// HopTab-style list of that app's windows so a specific one — not just
/// whichever it last had focused — gets raised on release.
///
/// Deliberately independent of `Coordinator`'s `HotkeyManager` — that one is
/// gated behind Accessibility permission (it manipulates window frames via
/// AX). Basic app-level activation here needs no permission at all; only the
/// per-window drill-down (`windowsForSelectedApp`) uses AX, and degrades
/// gracefully to app-only activation when it isn't granted — see
/// `refreshWindowsForSelectedAppAsync()`.
@MainActor
final class AppSwitcherController {
    private let hotkeyManager = HotkeyManager()
    private let hud: AppSwitcherHUDWindowController
    private var config: AppSwitcherConfig = .default

    /// Non-empty and `isActive` only while Option is physically held down
    /// after a ⌥Tab/⌥⇧Tab fire — cleared the instant Option is released
    /// (`commit()`) or Esc cancels the session.
    private var candidates: [AppSwitcherEntry] = []
    private var selectedIndex = 0
    private var isActive = false

    /// Entry keys (`AppSwitcherEntry.mruKey`) in most-recently-activated-first
    /// order, updated on every `NSWorkspace.didActivateApplicationNotification`
    /// regardless of `config.enabled` — so the ring reads warm (most-to-
    /// least-recent) from the very first ⌥Tab of a session rather than
    /// needing to "learn" it live. Not persisted: a fresh app launch has no
    /// history yet, and `AppSwitcherLogic.candidates` already falls back to
    /// config order for any allow-listed running app this hasn't seen
    /// activate yet.
    private var mruOrder: [String] = []
    private var activationObserver: NSObjectProtocol?
    /// `seedMRUOrder` needs `config.entries` to resolve profile-split
    /// ambiguity, which isn't available yet in `init` (before the first real
    /// `configure(_:)` call) — so seeding happens on the first `configure`
    /// call instead, guarded by this flag so later config edits don't
    /// clobber MRU state that's built up live since.
    private var hasSeededMRU = false

    /// Windows belonging to `candidates[selectedIndex]` on the current Space,
    /// refreshed every time the app-level selection changes via
    /// `AXWindowEnumerator.listVisibleWindows(forBundleID:)` — empty if
    /// Accessibility isn't granted (`try?` swallows the permission error,
    /// falling back to plain app-level activation). The HUD's window-list UI
    /// only renders when there's more than one — nothing to drill into for a
    /// single-window app — but `commit()` still raises that one window when
    /// present, which is harmless (equivalent to activating the app).
    private var windowsForSelectedApp: [AXWindow] = []
    private var selectedWindowIndex = 0

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?

    private static let forwardUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private static let reverseUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private static let windowDownUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    private static let windowUpUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
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
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            self?.recordActivation(bundleID)
        }
    }

    deinit {
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        if let globalKeyDownMonitor { NSEvent.removeMonitor(globalKeyDownMonitor) }
        if let localKeyDownMonitor { NSEvent.removeMonitor(localKeyDownMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    /// `NSWorkspace.didActivateApplicationNotification` only reports WHICH
    /// APP activated, not which window/profile — so when more than one
    /// configured entry shares this bundle ID (a "Personal"/"Work" Chrome
    /// split), the bundle ID alone is ambiguous. Resolved here via
    /// `resolveEntryKey`, which checks the app's actual frontmost window
    /// title against each candidate entry's `titleContains`; if that can't
    /// be resolved (AX not granted, or the title matches neither/both), this
    /// intentionally does nothing rather than guess — leaving whichever
    /// entry was last *correctly* resolved in place is better than
    /// incorrectly promoting one arbitrarily.
    private func recordActivation(_ bundleID: String) {
        guard let key = resolveEntryKey(forBundleID: bundleID, among: config.entries) else { return }
        mruOrder.removeAll { $0 == key }
        mruOrder.insert(key, at: 0)
    }

    /// Resolves a bare bundle ID (all `NSWorkspace`/`CGWindowList` give us)
    /// down to the specific `AppSwitcherEntry.mruKey` that's actually
    /// frontmost right now. Trivial when only one configured entry has this
    /// bundle ID; for a profile split, matches the app's current frontmost
    /// window title (first result from `listVisibleWindows(forBundleID:)`,
    /// which preserves the window server's own front-to-back z-order)
    /// against each candidate's `titleContains`.
    private func resolveEntryKey(forBundleID bundleID: String, among entries: [AppSwitcherEntry]) -> String? {
        let matches = entries.filter { $0.bundleID == bundleID }
        guard let first = matches.first else { return nil }
        guard matches.count > 1 else { return first.mruKey }
        guard AXPermission.check(),
              let frontTitle = (try? AXWindowEnumerator.listVisibleWindows(forBundleID: bundleID))?.first?.title
        else { return nil }
        return matches.first { entry in
            guard let filter = entry.titleContains, !filter.isEmpty else { return false }
            return frontTitle.localizedCaseInsensitiveContains(filter)
        }?.mruKey
    }

    /// Front-to-back order of on-screen windows' owning apps (one bundle ID
    /// per window-server z-order slot — `CGWindowListCopyWindowInfo` already
    /// returns entries in that order, and the frontmost window's app is by
    /// definition the most recently activated one), resolved down to entry
    /// keys via `resolveEntryKey` so a profile split seeds correctly too.
    /// Runs once, from `configure(_:)`, once `config.entries` is available —
    /// see `hasSeededMRU`. No Accessibility permission needed for the z-order
    /// scan itself; only the profile-split resolution step needs it, and
    /// degrades to "skip this bundle ID" rather than guessing when it's
    /// unavailable.
    private func seedMRUOrder() -> [String] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var seenBundleIDs = Set<String>()
        var seenKeys = Set<String>()
        var order: [String] = []
        for info in list {
            guard
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,
                let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                !seenBundleIDs.contains(bundleID)
            else { continue }
            seenBundleIDs.insert(bundleID)
            guard let key = resolveEntryKey(forBundleID: bundleID, among: config.entries), !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            order.append(key)
        }
        return order
    }

    /// Re-registers (or tears down) the ⌥Tab/⌥⇧Tab hotkeys to match the
    /// latest Settings. Safe to call repeatedly — call on launch and on
    /// every `SettingsStore.onChange` fire.
    func configure(_ config: AppSwitcherConfig) {
        self.config = config
        if !hasSeededMRU {
            hasSeededMRU = true
            // Seed from the window server's own z-order (front-to-back ==
            // most-to-least recently used) rather than starting empty.
            // Without this, every fresh launch/restart shows the ring in
            // configured (added) order until the user has manually switched
            // between these specific apps at least once this session — easy
            // to mistake for "it forgot my recency order" right after an
            // update restart, when really it just hadn't learned anything
            // yet. Deferred to here (rather than `init`) because resolving a
            // profile split needs `config.entries`, not available yet at
            // `init` time.
            mruOrder = seedMRUOrder()
        }
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
        hotkeyManager.register(
            uuid: Self.windowDownUUID,
            keyCode: HotkeyModifiers.downArrowKeyCode,
            modifiers: HotkeyModifiers.optionOnly,
            handler: { [weak self] in self?.navigateWindow(reverse: false) }
        )
        hotkeyManager.register(
            uuid: Self.windowUpUUID,
            keyCode: HotkeyModifiers.upArrowKeyCode,
            modifiers: HotkeyModifiers.optionOnly,
            handler: { [weak self] in self?.navigateWindow(reverse: true) }
        )
    }

    private func trigger(reverse: Bool) {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if !isActive {
            candidates = AppSwitcherLogic.candidates(
                config: config,
                mruOrder: mruOrder,
                runningBundleIDs: running,
                windowTitles: windowTitlesProvider
            )
            guard !candidates.isEmpty else { return }
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            selectedIndex = AppSwitcherLogic.startIndex(candidates: candidates, frontmostBundleID: frontmost)
            isActive = true
            installMonitors()
        } else {
            guard !candidates.isEmpty else { return }
            selectedIndex = AppSwitcherLogic.advance(index: selectedIndex, count: candidates.count, reverse: reverse)
        }
        // Show the tile/highlight change INSTANTLY — the per-window drill-down
        // list is refreshed asynchronously below and folded in as a follow-up
        // `showHUD()` once it lands. Previously this AX round trip
        // (`refreshWindowsForSelectedApp`, a synchronous cross-process call to
        // `kAXWindowsAttribute`) ran on the main thread before every single
        // `showHUD()`, on every Tab press — for apps slow to answer AX
        // queries (Chrome and other multi-process apps in particular) that
        // made the whole switcher feel like it was lagging behind the
        // keyboard, when only the drill-down sublist actually needed it.
        selectedWindowIndex = 0
        windowsForSelectedApp = []
        showHUD()
        refreshWindowsForSelectedAppAsync()
    }

    /// Backs `AppSwitcherLogic.candidates`' `titleContains` matching. Returns
    /// `[]` (dropping every title-filtered entry, per that function's own
    /// documented fallback) rather than guessing when AX isn't granted.
    private func windowTitlesProvider(bundleID: String) -> [String] {
        guard AXPermission.check() else { return [] }
        return ((try? AXWindowEnumerator.listVisibleWindows(forBundleID: bundleID)) ?? []).map { $0.title ?? "" }
    }

    /// ⌥↓ / ⌥↑ while the switcher is active: cycles which window of the
    /// currently-selected app will be raised on Option release. No-op if
    /// that app only has (or Accessibility can't see) one window — nothing
    /// to choose between.
    private func navigateWindow(reverse: Bool) {
        guard isActive, windowsForSelectedApp.count > 1 else { return }
        selectedWindowIndex = AppSwitcherLogic.advance(index: selectedWindowIndex, count: windowsForSelectedApp.count, reverse: reverse)
        showHUD()
    }

    /// Bumped on every call so a slow AX response for a selection the user
    /// has since tabbed away from can recognize it's stale and drop itself
    /// instead of clobbering a newer one — see `refreshWindowsForSelectedAppAsync`.
    private var windowsRefreshGeneration = 0

    private func refreshWindowsForSelectedAppAsync() {
        windowsRefreshGeneration += 1
        let thisGeneration = windowsRefreshGeneration
        guard AXPermission.check(), candidates.indices.contains(selectedIndex) else { return }
        let entry = candidates[selectedIndex]
        Task.detached(priority: .userInitiated) {
            let all = (try? AXWindowEnumerator.listVisibleWindows(forBundleID: entry.bundleID)) ?? []
            // A profile-split entry (titleContains set) drills down into only
            // ITS windows — landing on the "Work" Chrome tile shouldn't offer
            // Personal windows in the ⌥↓/⌥↑ list.
            let filtered: [AXWindow]
            if let filter = entry.titleContains, !filter.isEmpty {
                filtered = all.filter { ($0.title ?? "").localizedCaseInsensitiveContains(filter) }
            } else {
                filtered = all
            }
            await MainActor.run { [weak self] in
                guard let self, self.isActive, self.windowsRefreshGeneration == thisGeneration else { return }
                self.windowsForSelectedApp = filtered
                self.showHUD()
            }
        }
    }

    private func showHUD() {
        hud.show(
            entries: candidates,
            selectedIndex: selectedIndex,
            windowTitles: windowsForSelectedApp.map { $0.title ?? String(localized: "app_switcher.window.untitled") },
            selectedWindowIndex: selectedWindowIndex
        )
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
        let entry = candidates[selectedIndex]
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == entry.bundleID }) else { return }
        app.activate()

        if windowsForSelectedApp.indices.contains(selectedWindowIndex) {
            try? windowsForSelectedApp[selectedWindowIndex].raise()
            return
        }

        // `refreshWindowsForSelectedAppAsync()` may not have landed yet if
        // Option was released fast (that's the whole point of it being
        // async — Tab-cycling itself no longer waits on this). But raising
        // the SPECIFIC window still matters here, once, at the moment of
        // commit: `app.activate()` alone (a) raises whatever window this app
        // itself last had focus on, which for a profile-split entry (e.g.
        // "Personal" vs "Work" Chrome) can be the WRONG profile, and (b) has
        // been observed to not reliably bring that window above every other
        // on-screen window — an explicit AX raise is what actually does
        // that. So this does one synchronous fallback fetch — a one-shot
        // cost at commit, not a repeat of the original per-keystroke lag.
        let all = (try? AXWindowEnumerator.listVisibleWindows(forBundleID: entry.bundleID)) ?? []
        let windows: [AXWindow]
        if let filter = entry.titleContains, !filter.isEmpty {
            windows = all.filter { ($0.title ?? "").localizedCaseInsensitiveContains(filter) }
        } else {
            windows = all
        }
        if let toRaise = windows.first {
            try? toRaise.raise()
        }
    }

    private func finish() {
        isActive = false
        candidates = []
        selectedIndex = 0
        windowsForSelectedApp = []
        selectedWindowIndex = 0
        removeMonitors()
        hud.hide()
    }
}
