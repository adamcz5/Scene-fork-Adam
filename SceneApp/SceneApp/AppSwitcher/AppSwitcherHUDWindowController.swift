import AppKit
import SwiftUI
import SceneCore

/// Floating, borderless, non-activating panel showing the current ⌥Tab ring —
/// the classic-switcher-style overlay. Purely visual: `ignoresMouseEvents` is
/// on and the panel is never made key, so it can appear and disappear on
/// every Tab press without ever stealing focus from whatever app is
/// frontmost (`AppSwitcherController` reads that frontmost app to decide the
/// ring's start index and to detect Option release).
@MainActor
final class AppSwitcherHUDWindowController {
    private var window: NSPanel?

    func show(candidates: [String], selectedIndex: Int, windowTitles: [String] = [], selectedWindowIndex: Int = 0) {
        let panel: NSPanel
        if let existing = window {
            panel = existing
        } else {
            let p = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            // Display-only — clicks should pass through to whatever's under
            // the HUD rather than the (invisible, off-screen-ish) panel
            // swallowing them.
            p.ignoresMouseEvents = true
            window = p
            panel = p
        }

        let host = NSHostingController(rootView: AppSwitcherHUDView(
            candidates: candidates,
            selectedIndex: selectedIndex,
            windowTitles: windowTitles,
            selectedWindowIndex: selectedWindowIndex
        ))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.contentView?.layoutSubtreeIfNeeded()

        let screen = ScreenResolver.activeScreen()
        let size = panel.frame.size == .zero
            ? CGSize(width: 360, height: 160)
            : panel.frame.size
        let origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )
        panel.setFrame(CGRect(origin: origin, size: size), display: false)

        // `orderFrontRegardless()`, NOT `makeKeyAndOrderFront` / `NSApp.activate`
        // — showing the HUD must never change which app is frontmost or steal
        // key status, or the whole "hold Option, watch the frontmost app's
        // modifier flags" flow breaks.
        panel.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }
}
