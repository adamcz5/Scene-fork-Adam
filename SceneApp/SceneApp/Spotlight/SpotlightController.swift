import AppKit
import ApplicationServices
import CoreGraphics
import os
import SceneCore

/// Drives "Spotlight" — a dim+blur overlay (one `SpotlightOverlayWindow` per
/// screen) that darkens everything except the active window or app. See
/// `SpotlightConfig`'s doc comment for why this is NOT named `FocusMode`
/// (that name is already `Workspace.focusMode`'s macOS-Focus-Shortcut
/// integration, an unrelated feature).
///
/// State machine, driven entirely by AX notifications (needs Accessibility,
/// same gate as `Coordinator`'s window-tiling features):
/// - Any interaction (app activated, focused window changed within an app,
///   focused window moved/resized) → `interactionOccurred()`: cancel the
///   pending show-timer, fade the overlay out (if showing), start a fresh
///   `idleDelaySeconds` timer.
/// - Timer fires → compute the current exclusion rect(s) for `config.scope`
///   and fade the overlay in with holes cut at those rects.
///
/// Independent of `Coordinator`'s own AX observers (drag-swap/seam-resize) —
/// those track PLACED windows from the last applied layout; this tracks
/// whatever window happens to be frontmost at any moment, layout or not.
@MainActor
final class SpotlightController {
    private var config: SpotlightConfig = .default
    private var permissionGranted = false

    private var overlays: [SpotlightOverlayWindow] = []
    private var isShown = false
    private var showTimer: Timer?

    private var frontmostPID: pid_t?
    private var appElement: AXUIElement?
    private var appObserver: AXObserver?
    private var windowElement: AXUIElement?
    private var windowObserver: AXObserver?

    private var activationObserver: NSObjectProtocol?
    private var screenChangeObserver: NSObjectProtocol?

    private let log = Logger(subsystem: "com.scene.app", category: "spotlight")

    init() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in self?.handleFrontmostAppChanged(pid: pid) }
        }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildOverlays() }
        }
    }

    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let screenChangeObserver { NotificationCenter.default.removeObserver(screenChangeObserver) }
    }

    /// Mirrors `AppSwitcherController.configure(_:)`'s independence from
    /// `Coordinator` — called directly from `AppDelegate` on launch and on
    /// every `SettingsStore` change.
    func configure(_ newConfig: SpotlightConfig) {
        let shouldRun = newConfig.enabled && permissionGranted
        let wasRunning = config.enabled && permissionGranted
        config = newConfig
        if shouldRun, !wasRunning {
            start()
        } else if !shouldRun, wasRunning {
            stop()
        } else if shouldRun {
            // Already running, something about scope/delay changed — treat
            // as an interaction so the new config takes effect on the next
            // idle period rather than mid-display with stale settings.
            interactionOccurred()
        }
    }

    /// Called from the same place `AppDelegate` updates its own published
    /// `permissionGranted` — see `Coordinator.onPermissionChange`.
    func setPermissionGranted(_ granted: Bool) {
        guard granted != permissionGranted else { return }
        permissionGranted = granted
        if config.enabled, granted {
            start()
        } else if !granted {
            stop()
        }
    }

    // MARK: - Lifecycle

    private func start() {
        guard overlays.isEmpty else { return }
        rebuildOverlays()
        handleFrontmostAppChanged(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    private func stop() {
        showTimer?.invalidate()
        showTimer = nil
        teardownAppObserver()
        teardownWindowObserver()
        for overlay in overlays { overlay.hide(immediate: true) }
        overlays.removeAll()
        isShown = false
        frontmostPID = nil
    }

    private func rebuildOverlays() {
        for overlay in overlays { overlay.hide(immediate: true) }
        guard config.enabled, permissionGranted else {
            overlays = []
            return
        }
        overlays = NSScreen.screens.map { SpotlightOverlayWindow(screen: $0) }
        isShown = false
    }

    // MARK: - AX tracking

    private func handleFrontmostAppChanged(pid: pid_t?) {
        interactionOccurred()
        teardownAppObserver()
        teardownWindowObserver()
        frontmostPID = pid
        guard config.enabled, permissionGranted, let pid else { return }

        // Scene itself (menu-bar-only) becoming "frontmost" — e.g. opening
        // Settings — should never trigger dimming around a Scene window.
        if pid == ProcessInfo.processInfo.processIdentifier { return }

        let element = AXUIElementCreateApplication(pid)
        appElement = element

        var observer: AXObserver?
        let createErr = AXObserverCreate(pid, Self.observerCallback, &observer)
        guard createErr == .success, let observer else {
            log.error("AXObserverCreate(app) failed pid=\(pid, privacy: .public) err=\(createErr.rawValue, privacy: .public)")
            handleFocusedWindowChanged()
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let addErr = AXObserverAddNotification(observer, element, kAXFocusedWindowChangedNotification as CFString, refcon)
        if addErr == .success {
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            appObserver = observer
        } else {
            log.error("AXObserverAddNotification(focusedWindowChanged) failed pid=\(pid, privacy: .public) err=\(addErr.rawValue, privacy: .public)")
        }

        handleFocusedWindowChanged()
    }

    private func handleFocusedWindowChanged() {
        interactionOccurred()
        teardownWindowObserver()
        guard config.enabled, permissionGranted, let appElement, let pid = frontmostPID else { return }

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef
        else { return }
        let element = focused as! AXUIElement
        windowElement = element

        var observer: AXObserver?
        let createErr = AXObserverCreate(pid, Self.observerCallback, &observer)
        guard createErr == .success, let observer else {
            log.error("AXObserverCreate(window) failed pid=\(pid, privacy: .public) err=\(createErr.rawValue, privacy: .public)")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var anySucceeded = false
        for notif in [kAXMovedNotification, kAXResizedNotification] {
            if AXObserverAddNotification(observer, element, notif as CFString, refcon) == .success {
                anySucceeded = true
            }
        }
        if anySucceeded {
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            windowObserver = observer
        }
    }

    private func teardownAppObserver() {
        if let appObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(appObserver), .commonModes)
        }
        appObserver = nil
        appElement = nil
    }

    private func teardownWindowObserver() {
        if let windowObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(windowObserver), .commonModes)
        }
        windowObserver = nil
        windowElement = nil
    }

    // C-style callback: no captured context. `refcon` is `self`, passed
    // unretained (the controller outlives every observer it creates — see
    // `AXMoveObserverGroup` for the identical pattern). Both the app-level
    // `kAXFocusedWindowChangedNotification` and the window-level move/resize
    // notifications route through the SAME callback; which one fired only
    // matters for `handleFocusedWindowChanged` vs `interactionOccurred` — and
    // since `handleFocusedWindowChanged` already calls `interactionOccurred`
    // first, every notification can safely funnel through one dispatch.
    private static let observerCallback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let controller = Unmanaged<SpotlightController>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated {
            if notification as String == (kAXFocusedWindowChangedNotification as String) {
                controller.handleFocusedWindowChanged()
            } else {
                controller.interactionOccurred()
            }
        }
    }

    // MARK: - Show/hide timing

    private func interactionOccurred() {
        showTimer?.invalidate()
        showTimer = nil
        if isShown {
            for overlay in overlays { overlay.hide() }
            isShown = false
        }
        guard config.enabled, permissionGranted else { return }
        showTimer = Timer.scheduledTimer(withTimeInterval: config.idleDelaySeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.showSpotlight() }
        }
    }

    private func showSpotlight() {
        showTimer = nil
        guard config.enabled, permissionGranted else { return }
        let frames = currentExclusionFrames()
        // Nothing to protect (no focused window resolvable, or the
        // frontmost app has no visible windows) — showing a full-screen dim
        // with no hole at all would be actively unhelpful, so skip.
        guard !frames.isEmpty else { return }
        for overlay in overlays {
            overlay.updateHoles(excludedFrames: frames, screenFrame: overlay.frame)
            overlay.show()
        }
        isShown = true
    }

    private func currentExclusionFrames() -> [CGRect] {
        switch config.scope {
        case .activeWindow:
            guard let windowElement, let axFrame = AXWindowLookup.axFrame(of: windowElement) else { return [] }
            return [DisplayCoordinates.axToNS(axFrame)]
        case .activeApp:
            guard let pid = frontmostPID,
                  let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                  let windows = try? AXWindowEnumerator.listVisibleWindows(forBundleID: bundleID)
            else { return [] }
            return windows.map(\.frame)
        }
    }
}
