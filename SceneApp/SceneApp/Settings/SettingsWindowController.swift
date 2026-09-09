import AppKit
import SwiftUI

/// Hosts `SettingsRoot` in a real `NSWindow` (rather than a `Settings { }` Scene)
/// so the menu-bar app stays in `.accessory` activation policy by default and
/// only flips to `.regular` while the Settings window is on screen — avoiding a
/// permanent Dock icon for a menu-bar utility.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let layoutVM: LayoutStoreViewModel
    private let settingsVM: SettingsStoreViewModel
    private let workspaceVM: WorkspaceStoreViewModel

    init(
        layoutVM: LayoutStoreViewModel,
        settingsVM: SettingsStoreViewModel,
        workspaceVM: WorkspaceStoreViewModel,
        calendarPermissionRequester: @escaping () async -> Bool,
        reopenWelcome: @escaping () -> Void,
        exportDiagnostics: @escaping () async -> Void
    ) {
        self.layoutVM = layoutVM
        self.settingsVM = settingsVM
        self.workspaceVM = workspaceVM
        let host = NSHostingController(
            rootView: SettingsRoot(
                calendarPermissionRequester: calendarPermissionRequester,
                reopenWelcome: reopenWelcome,
                exportDiagnostics: exportDiagnostics
            )
                .environmentObject(layoutVM)
                .environmentObject(settingsVM)
                .environmentObject(workspaceVM)
                .modifier(WindowBackdrop())
        )
        // The hosting controller MUST be the window's root `contentViewController`.
        // `NSHostingController` only bridges its SwiftUI `.toolbar` content into
        // `view.window.toolbar` when it owns the window's content; as a *child*
        // view controller the bridge never happens and every toolbar button
        // silently disappears (issue #4 — regressed v0.7.2 through v0.7.4, when
        // the macOS 26 translucency backdrop was an NSVisualEffectView container
        // VC wrapping this host). The backdrop is now a SwiftUI background layer
        // instead, which keeps the toolbar bridge intact.
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 760, height: 540))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = String(localized: "settings.window.title")
        window.isReleasedWhenClosed = false
        if #available(macOS 26.0, *) {
            // Tahoe-style chrome: sidebar glass floats edge-to-edge under a
            // transparent title bar. window.title stays set above for Mission
            // Control / App Exposé / accessibility.
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for SettingsWindowController")
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Whole-window translucency on macOS 26, applied as a SwiftUI background rather
/// than an AppKit container view controller — see the toolbar-bridge note in
/// `SettingsWindowController.init`. `SwiftUI.containerBackground(for: .window)`
/// still does not bridge into a manually hosted `NSWindow`, so the material is
/// an `NSVisualEffectView` behind the SwiftUI hierarchy, whose own backgrounds
/// stay clear (see `DetailTabChrome` in `SettingsRoot`). No-op on macOS 14/15.
private struct WindowBackdrop: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.background(VisualEffectBackdrop().ignoresSafeArea())
        } else {
            content
        }
    }
}

private struct VisualEffectBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
