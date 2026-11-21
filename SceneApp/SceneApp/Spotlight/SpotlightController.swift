import AppKit
import ApplicationServices
import CoreGraphics
import os
import SceneCore

/// Drives "Spotlight" — a dim+blur overlay (one `SpotlightOverlayWindow` per
/// screen) that darkens everything except the active window. See
/// `SpotlightConfig`'s doc comment for why this is NOT named `FocusMode`
/// (that name is already `Workspace.focusMode`'s macOS-Focus-Shortcut
/// integration, an unrelated feature).
///
/// State machine, driven entirely by AX notifications (needs Accessibility,
/// same gate as `Coordinator`'s window-tiling features):
/// - Any interaction (app activated, focused window changed within an app,
///   focused window moved/resized) → `interactionOccurred()`: cancel the
///   pending show-timer, fade the overlay out (if showing), start a fresh
///   `idleDelaySeconds` timer. Exception: focusing a window that is already
///   inside a shown hole (e.g. hopping between per-monitor apps that are each
///   visible) is a no-op — see `handleFocusedWindowChanged`.
/// - Timer fires → compute the current exclusion rect(s) for
///   `config.exclusionMode` and fade the overlay in with holes cut there.
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
    /// The exclusion rects punched into the overlay while it's showing (NS
    /// coordinates). Used to tell whether a newly-focused window is ALREADY
    /// undimmed, in which case focusing it must not dissolve the dim.
    private var shownExclusionFrames: [CGRect] = []
    private var stripTimer: Timer?
    private var showTimer: Timer?
    /// Browser top-bar dimming layers (one per excluded browser window) and the
    /// pointer poll that hides each while the mouse is over it.
    private var stripPanels: [SpotlightStripPanel] = []
    private var stripFrames: [CGRect] = []
    private var hoverTimer: Timer?

    private var frontmostPID: pid_t?
    private var appElement: AXUIElement?
    private var appObserver: AXObserver?
    private var windowElement: AXUIElement?
    private var windowObserver: AXObserver?

    /// For `.perMonitor` exclusion mode: the last app/window that was active
    /// on each screen, keyed by `CGDirectDisplayID`. Updated every time the
    /// focused window resolves to a screen (see `handleFocusedWindowChanged`)
    /// — NOT cleared when focus moves to another screen, so a screen keeps
    /// showing its own last-active window undimmed even while you're
    /// actively working on a different one. Ignored entirely in `.single` mode.
    private var perScreenTargets: [CGDirectDisplayID: PerScreenTarget] = [:]

    private struct PerScreenTarget {
        let pid: pid_t
        let windowElement: AXUIElement?
    }

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
        let oldConfig = config
        config = newConfig
        for overlay in overlays { overlay.apply(config: newConfig) }
        for panel in stripPanels { panel.apply(config: newConfig) }
        if shouldRun, wasRunning, isShown, Self.onlyTabBarSwitchChanged(from: oldConfig, to: newConfig) {
            // Tab-bar dimming switched on/off (or Lite toggled) while the rest
            // is already dimmed: just the top bar changes, on its own timing.
            stripTimer?.invalidate()
            stripTimer = nil
            if !newConfig.dimBrowserChrome {
                hideStrips()
            } else if stripPanels.isEmpty {
                stripTimer = Timer.scheduledTimer(withTimeInterval: newConfig.browserChromeDelaySeconds, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.showBrowserStrips() }
                }
            }
        } else if shouldRun, !wasRunning {
            start()
        } else if !shouldRun, wasRunning {
            stop()
        } else if shouldRun {
            // Already running, something about the config changed — treat
            // as an interaction so the new config takes effect on the next
            // idle period rather than mid-display with stale settings.
            interactionOccurred()
        }
    }

    private static func onlyTabBarSwitchChanged(from old: SpotlightConfig, to new: SpotlightConfig) -> Bool {
        var probe = old
        probe.dimBrowserChrome = new.dimBrowserChrome
        probe.browserChromeLight = new.browserChromeLight
        return probe == new && (old.dimBrowserChrome != new.dimBrowserChrome || old.browserChromeLight != new.browserChromeLight)
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
        stripTimer?.invalidate()
        stripTimer = nil
        teardownAppObserver()
        teardownWindowObserver()
        for overlay in overlays { overlay.hide(immediate: true) }
        hideStrips(immediate: true)
        overlays.removeAll()
        isShown = false
        shownExclusionFrames = []
        frontmostPID = nil
        perScreenTargets.removeAll()
    }

    private func rebuildOverlays() {
        for overlay in overlays { overlay.hide(immediate: true) }
        hideStrips(immediate: true)
        guard config.enabled, permissionGranted else {
            overlays = []
            return
        }
        overlays = NSScreen.screens.map { screen in
            let overlay = SpotlightOverlayWindow(screen: screen)
            overlay.apply(config: config)
            return overlay
        }
        isShown = false
        shownExclusionFrames = []
    }

    // MARK: - AX tracking

    private func handleFrontmostAppChanged(pid: pid_t?) {
        teardownAppObserver()
        teardownWindowObserver()
        frontmostPID = pid
        guard config.enabled, permissionGranted, let pid else {
            interactionOccurred()
            return
        }

        // Scene itself (menu-bar-only) becoming "frontmost" — e.g. opening
        // Settings — should never trigger dimming around a Scene window.
        if pid == ProcessInfo.processInfo.processIdentifier {
            interactionOccurred()
            return
        }

        // A Chromium browser only builds its accessibility tree once asked, and
        // the tree takes a moment to fill in — start that now, long before the
        // dim fades in, so the top bar can actually be found by then.
        if config.dimBrowserChrome,
           BrowserChromeDetector.isCandidate(bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier) {
            BrowserChromeDetector.prepare(pid: pid)
        }

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

    /// Resolves the newly focused window and decides whether this counts as an
    /// "interaction" (dissolve the dim, restart the idle timer) or not.
    ///
    /// Focusing a window that is ALREADY undimmed — e.g. hopping between the
    /// per-monitor apps that are each visible — changes nothing the user can
    /// see, so it must not flicker the overlay off and back on. Only moving
    /// focus to something that is currently dimmed (or anything unresolvable)
    /// takes the normal dissolve + re-arm path.
    private func handleFocusedWindowChanged() {
        teardownWindowObserver()
        guard config.enabled, permissionGranted, let appElement, let pid = frontmostPID else {
            interactionOccurred()
            return
        }

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef
        else {
            interactionOccurred()
            return
        }
        let element = focused as! AXUIElement
        windowElement = element
        recordPerScreenTarget(pid: pid, windowElement: element)

        var observer: AXObserver?
        let createErr = AXObserverCreate(pid, Self.observerCallback, &observer)
        if createErr == .success, let observer {
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
        } else {
            log.error("AXObserverCreate(window) failed pid=\(pid, privacy: .public) err=\(createErr.rawValue, privacy: .public)")
        }

        if isShown, isAlreadyUndimmed(windowElement: element) {
            return
        }
        interactionOccurred()
    }

    /// Whether `windowElement` currently sits inside a hole of the SHOWN
    /// overlay. `.single` mode has one hole around one window, so it needs
    /// that same window (frames equal); `.perMonitor` keeps one hole per
    /// screen, so any window within one of them is already visible.
    private func isAlreadyUndimmed(windowElement: AXUIElement) -> Bool {
        guard let axFrame = AXWindowLookup.axFrame(of: windowElement) else { return false }
        let frame = DisplayCoordinates.axToNS(axFrame)
        let tolerance: CGFloat = 2
        switch config.exclusionMode {
        case .single:
            return shownExclusionFrames.contains { shown in
                abs(shown.minX - frame.minX) <= tolerance && abs(shown.minY - frame.minY) <= tolerance &&
                abs(shown.width - frame.width) <= tolerance && abs(shown.height - frame.height) <= tolerance
            }
        case .perMonitor:
            return shownExclusionFrames.contains { shown in
                shown.insetBy(dx: -tolerance, dy: -tolerance).contains(frame)
            }
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
        stripTimer?.invalidate()
        stripTimer = nil
        if !stripPanels.isEmpty { hideStrips() }
        if isShown {
            for overlay in overlays { overlay.hide() }
            isShown = false
            shownExclusionFrames = []
        }
        guard config.enabled, permissionGranted else { return }
        showTimer = Timer.scheduledTimer(withTimeInterval: config.idleDelaySeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.showSpotlight() }
        }
    }

    private func showSpotlight() {
        showTimer = nil
        guard config.enabled, permissionGranted else { return }
        var frames = currentExclusionFrames()
        // Nothing to protect (no focused window resolvable, or the
        // frontmost app has no visible windows) — showing a full-screen dim
        // with no hole at all would be actively unhelpful, so skip.
        guard !frames.isEmpty else { return }
        frames += exceptionAppFrames()
        for overlay in overlays {
            overlay.updateHoles(excludedFrames: frames, screenFrame: overlay.frame)
            overlay.show()
        }
        // First dim after everything was clear: the top bar comes in at the
        // same moment and with the same fade as the rest.
        if config.dimBrowserChrome {
            showStrips(currentBrowserChromeFrames(), mainTiming: true)
        }
        isShown = true
        shownExclusionFrames = frames
    }

    // MARK: - Browser top-bar strips

    /// The top bar has its own delay, so it can come in before or after the
    /// main dim; it only needs Dim on and a recognized browser in front.
    private func showBrowserStrips() {
        stripTimer = nil
        guard config.enabled, permissionGranted, config.dimBrowserChrome else { return }
        showStrips(currentBrowserChromeFrames(), mainTiming: false)
    }

    private func showStrips(_ frames: [CGRect], mainTiming: Bool) {
        hideStrips(immediate: true)
        guard !frames.isEmpty else { return }
        stripFrames = frames
        stripPanels = frames.map { frame in
            let panel = SpotlightStripPanel(frame: frame)
            panel.apply(config: config)
            panel.fadeSpeedOverride = mainTiming ? config.speed : nil
            // Already hovering when the dim arrives: start faded out instead
            // of flashing in for a poll tick.
            panel.setHovered(frame.contains(NSEvent.mouseLocation))
            panel.show()
            return panel
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStripHover() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func hideStrips(immediate: Bool = false) {
        hoverTimer?.invalidate()
        hoverTimer = nil
        for panel in stripPanels { panel.hide(immediate: immediate) }
        stripPanels = []
        stripFrames = []
    }

    /// The strip panels ignore mouse events (clicks must reach the browser), so
    /// hover is detected by polling the pointer against each strip's frame.
    private func updateStripHover() {
        let mouse = NSEvent.mouseLocation
        for (panel, frame) in zip(stripPanels, stripFrames) {
            panel.setHovered(frame.contains(mouse))
        }
    }

    private func currentExclusionFrames() -> [CGRect] {
        switch config.exclusionMode {
        case .single:
            return exclusionFrame(of: windowElement).map { [$0] } ?? []
        case .perMonitor:
            // One exclusion target per screen, each computed from THAT
            // screen's own last-recorded target rather than the global
            // frontmost one — see `recordPerScreenTarget`.
            var frames: [CGRect] = []
            for screen in NSScreen.screens {
                guard let id = Self.displayID(for: screen), let target = perScreenTargets[id],
                      let frame = exclusionFrame(of: target.windowElement)
                else { continue }
                frames.append(frame)
            }
            return frames
        }
    }

    /// Visible, normal-layer windows of the apps the user listed as never to
    /// be dimmed, in NS screen coordinates. Uses the window list (no
    /// accessibility needed) and is evaluated each time the dim fades in.
    private func exceptionAppFrames() -> [CGRect] {
        let ids = Set(config.exceptionBundleIDs)
        guard !ids.isEmpty else { return [] }
        let pids = Set(NSWorkspace.shared.runningApplications.compactMap { app -> pid_t? in
            guard let id = app.bundleIdentifier, ids.contains(id) else { return nil }
            return app.processIdentifier
        })
        guard !pids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var result: [CGRect] = []
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let cgFrame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  cgFrame.width > 40, cgFrame.height > 40
            else { continue }
            result.append(DisplayCoordinates.axToNS(cgFrame))
        }
        return result
    }

    private func exclusionFrame(of windowElement: AXUIElement?) -> CGRect? {
        guard let windowElement, let axFrame = AXWindowLookup.axFrame(of: windowElement) else { return nil }
        return DisplayCoordinates.axToNS(axFrame)
    }

    /// EXPERIMENTAL (see `BrowserChromeDetector`) — the sub-rects to re-darken
    /// inside whatever's currently excluded, for browsers Scene recognizes.
    /// Mirrors `currentExclusionFrames`'s single/perMonitor split so chrome
    /// dimming covers the same target(s) the exclusion itself covers.
    private func currentBrowserChromeFrames() -> [CGRect] {
        switch config.exclusionMode {
        case .single:
            return browserChromeFrames(pid: frontmostPID, windowElement: windowElement)
        case .perMonitor:
            var frames: [CGRect] = []
            for target in perScreenTargets.values {
                frames.append(contentsOf: browserChromeFrames(pid: target.pid, windowElement: target.windowElement))
            }
            return frames
        }
    }

    private func browserChromeFrames(pid: pid_t?, windowElement: AXUIElement?) -> [CGRect] {
        guard let pid, let windowElement,
              let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        else { return [] }
        // Idempotent; covers the case where the setting was switched on while
        // this browser was already frontmost.
        if BrowserChromeDetector.isCandidate(bundleID: bundleID) { BrowserChromeDetector.prepare(pid: pid) }
        return BrowserChromeDetector.chromeRegions(
            windowElement: windowElement,
            bundleID: bundleID,
            mode: config.browserChromeMode,
            fixedHeight: config.browserChromeHeight
        ) ?? []
    }

    /// Remembers which screen a just-focused window landed on, so
    /// `.perMonitor` mode can later ask "what was last active on screen X"
    /// independently of whatever's frontmost system-wide right now.
    private func recordPerScreenTarget(pid: pid_t, windowElement: AXUIElement) {
        guard let axFrame = AXWindowLookup.axFrame(of: windowElement) else { return }
        let nsFrame = DisplayCoordinates.axToNS(axFrame)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(nsFrame) }),
              let id = Self.displayID(for: screen)
        else { return }
        perScreenTargets[id] = PerScreenTarget(pid: pid, windowElement: windowElement)
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
