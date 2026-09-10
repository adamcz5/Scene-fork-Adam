import AppKit
import SwiftUI
import SceneCore

/// Hosts the hotkey-triggered Workspace Quick Picker: a small floating,
/// borderless panel listing Workspaces with `showInQuickPicker == true` as
/// clickable tiles (layout thumbnail + name), so switching doesn't require
/// the menu bar click or remembering a per-workspace chord. Modeled after
/// `OnboardingWindowController`'s lazy-create-then-show/hide pattern.
@MainActor
final class WorkspacePickerWindowController {
    private var window: NSPanel?
    private let workspaceStore: WorkspaceStoreViewModel
    private let layoutStore: LayoutStoreViewModel
    private let onSelect: (UUID) -> Void
    /// Row 2's "pick a layout, then assign apps per zone, then apply" flow —
    /// this is a one-off arrangement, not backed by a saved `Workspace`, so it
    /// hands back the `CustomLayout` plus whatever ad-hoc
    /// `WorkspaceSlotAssignment`s the user picked instead of a UUID.
    private let onApplyLayout: (CustomLayout, [WorkspaceSlotAssignment]) -> Void

    /// Fires on any mouse-down in another app while the panel is visible.
    /// Global monitors only see events destined for *other* apps — see
    /// `localClickMonitor` for clicks that land on one of Scene's own
    /// other windows (e.g. Settings).
    private var globalClickMonitor: Any?
    /// Fires on any mouse-down within Scene itself. Dismisses when the click
    /// lands on a window other than this panel (e.g. the Settings window
    /// sitting behind it) — a plain `NSWindow.didResignKeyNotification`
    /// observer doesn't reliably fire for a `.nonactivatingPanel`, since
    /// those are designed to hold key status a little looser than a normal
    /// window.
    private var localClickMonitor: Any?

    init(
        workspaceStore: WorkspaceStoreViewModel,
        layoutStore: LayoutStoreViewModel,
        onSelect: @escaping (UUID) -> Void,
        onApplyLayout: @escaping (CustomLayout, [WorkspaceSlotAssignment]) -> Void
    ) {
        self.workspaceStore = workspaceStore
        self.layoutStore = layoutStore
        self.onSelect = onSelect
        self.onApplyLayout = onApplyLayout
    }

    func show() {
        let panel: NSPanel
        if let existing = window {
            panel = existing
        } else {
            let view = WorkspaceQuickPickerView(
                workspaceStore: workspaceStore,
                layoutStore: layoutStore,
                onSelect: { [weak self] id in
                    self?.onSelect(id)
                    self?.hide()
                },
                onApplyLayout: { [weak self] layout, assignments in
                    self?.onApplyLayout(layout, assignments)
                    self?.hide()
                },
                onDismiss: { [weak self] in self?.hide() }
            )
            let host = NSHostingController(rootView: view)
            // Let the panel size itself to fit however many workspace tiles
            // there are — no internal scrolling, the panel just grows.
            host.sizingOptions = [.preferredContentSize]
            let p = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            p.contentViewController = host
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            window = p
            panel = p
        }

        // Force a layout pass now so `panel.frame.size` reflects the SwiftUI
        // content's actual fitted size (via `sizingOptions` above) before we
        // use it to compute a centered origin below — without this the size
        // read here can lag a runloop tick behind the workspace count.
        panel.contentView?.layoutSubtreeIfNeeded()

        // Center on the screen under the mouse — same "wherever you're
        // looking" heuristic ScreenResolver.activeScreen() uses for layout
        // application, so the picker shows up where you're working.
        let screen = ScreenResolver.activeScreen()
        let size = panel.frame.size == .zero
            ? CGSize(width: 420, height: 420)
            : panel.frame.size
        let origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )
        panel.setFrame(CGRect(origin: origin, size: size), display: false)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installDismissMonitors(for: panel)
    }

    func hide() {
        window?.orderOut(nil)
        removeDismissMonitors()
    }

    private func installDismissMonitors(for panel: NSPanel) {
        removeDismissMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self, weak panel] event in
            if event.window !== panel { self?.hide() }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
    }
}
