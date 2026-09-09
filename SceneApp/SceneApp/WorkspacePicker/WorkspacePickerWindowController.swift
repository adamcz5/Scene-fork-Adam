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

    init(
        workspaceStore: WorkspaceStoreViewModel,
        layoutStore: LayoutStoreViewModel,
        onSelect: @escaping (UUID) -> Void
    ) {
        self.workspaceStore = workspaceStore
        self.layoutStore = layoutStore
        self.onSelect = onSelect
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
                onDismiss: { [weak self] in self?.hide() }
            )
            let host = NSHostingController(rootView: view)
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
            // Dismiss on click-away, like a command palette / menu — clicking
            // any other window resigns this one's key status.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: p,
                queue: .main
            ) { [weak self] _ in self?.hide() }
            window = p
            panel = p
        }

        // Center on the screen under the mouse — same "wherever you're
        // looking" heuristic ScreenResolver.activeScreen() uses for layout
        // application, so the picker shows up where you're working.
        let screen = ScreenResolver.activeScreen()
        let size = panel.frame.size == .zero
            ? CGSize(width: 480, height: 320)
            : panel.frame.size
        let origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )
        panel.setFrame(CGRect(origin: origin, size: size), display: false)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }
}
