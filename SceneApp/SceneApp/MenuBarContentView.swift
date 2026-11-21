import SwiftUI
import AppKit
import SceneCore

struct MenuBarContentView: View {
    // Observe the coordinator directly rather than via @EnvironmentObject.
    // MenuBarExtra's menu (like its label — see MenuBarLabel) does NOT reliably
    // re-subscribe to @Published changes from environment objects, so toggling
    // Free Mode from the menu could leave the menu showing stale state (the
    // "Free Mode won't toggle back" report). A direct @ObservedObject binding
    // makes freeMode changes invalidate the menu the same way the icon updates.
    @ObservedObject var coordinator: Coordinator
    @EnvironmentObject var appDelegate: AppDelegate
    @EnvironmentObject var updateChecker: UpdateChecker
    @EnvironmentObject var updateInstaller: UpdateInstaller
    // Direct @ObservedObject, not @EnvironmentObject — same reasoning as
    // `coordinator` above: the sticky-mode row needs to repaint the instant
    // the mode is cycled from the menu itself.
    @ObservedObject var settingsVM: SettingsStoreViewModel
    @ObservedObject var workspaceStore: WorkspaceStoreViewModel
    @ObservedObject var layoutStore: LayoutStoreViewModel

    /// Hosting NSWindow of the window-style panel, captured via
    /// PanelWindowAccessor so actions can dismiss the panel explicitly
    /// (update-banner alert, Settings, onboarding, Escape). Layout,
    /// workspace, and Free Mode clicks deliberately do NOT dismiss —
    /// that is the point of the window-style panel.
    @State private var panelWindow: NSWindow?

    /// Layouts are collapsed by default — the list is long and workspaces are
    /// the primary way to apply things from this panel.
    @State private var layoutsExpanded = false

    var body: some View {
        Group {
            if coordinator.permissionGranted {
                grantedPanel
            } else {
                ungrantedPanel
            }
        }
        .frame(width: 280)
        .background(PanelWindowAccessor(window: $panelWindow))
        .onExitCommand { closePanel() }
    }

    // MARK: - Granted

    @ViewBuilder
    private var grantedPanel: some View {
        // Touch layoutListVersion so SwiftUI rebuilds when LayoutStore mutates.
        let _ = coordinator.layoutListVersion

        VStack(alignment: .leading, spacing: 2) {
            if let version = updateChecker.availableVersion,
               let releaseURL = updateChecker.releasePageURL {
                Button(action: {
                    // Close first — runModal over an open panel fights for focus.
                    closePanel()
                    handleUpdateClick(version: version, releaseURL: releaseURL)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.tint)
                        Text(String(format: String(localized: "menu.update.available"), version))
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .buttonStyle(MenuRowButtonStyle())
                PanelDivider()
            }

            dimTilesRow

            PanelDivider()

            sectionHeader("menu.section.workspaces")
            if workspaceStore.workspaces.isEmpty {
                Text("menu.workspaces.empty")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            } else {
                ForEach(workspaceStore.workspaces) { workspace in
                    workspaceRow(workspace)
                }
            }

            PanelDivider()

            layoutsDisclosureRow
            if layoutsExpanded {
                ForEach(layoutStore.layouts) { layout in
                    layoutRow(layout)
                }
            }

            PanelDivider()

            Button(action: { coordinator.resetActiveLayout() }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("menu.reset_layout")
                    Spacer()
                }
            }
            .buttonStyle(MenuRowButtonStyle())
            .disabled(coordinator.freeMode || coordinator.activeLayoutID == nil)
            .help("menu.reset_layout.help")

            Button(action: { coordinator.freeMode.toggle() }) {
                HStack(spacing: 6) {
                    checkmarkColumn(coordinator.freeMode)
                    Text("menu.free_mode")
                    Spacer()
                }
            }
            .buttonStyle(MenuRowButtonStyle())

            stickyModeRow

            PanelDivider()

            Button(action: {
                closePanel()
                appDelegate.openSettings()
            }) {
                HStack { Text("menu.settings"); Spacer() }
            }
            .buttonStyle(MenuRowButtonStyle())
            .keyboardShortcut(",")

            Button(action: { NSApp.terminate(nil) }) {
                HStack { Text("menu.quit"); Spacer() }
            }
            .buttonStyle(MenuRowButtonStyle())
            .keyboardShortcut("q")
        }
        .padding(6)
    }

    // MARK: - Ungranted

    @ViewBuilder
    private var ungrantedPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: {
                closePanel()
                coordinator.openOnboarding()
            }) {
                HStack { Text("menu.grant_accessibility"); Spacer() }
            }
            .buttonStyle(MenuRowButtonStyle())

            PanelDivider()

            Button(action: { NSApp.terminate(nil) }) {
                HStack { Text("menu.quit"); Spacer() }
            }
            .buttonStyle(MenuRowButtonStyle())
        }
        .padding(6)
    }

    // MARK: - Rows

    private func workspaceRow(_ workspace: Workspace) -> some View {
        Button(action: { activate(workspace: workspace) }) {
            HStack(spacing: 6) {
                checkmarkColumn(workspaceStore.activeWorkspaceID == workspace.id)
                if let layout = layoutStore.layouts.first(where: { $0.id == workspace.layoutID }) {
                    LayoutThumbnail(layout: layout, size: CGSize(width: 24, height: 16))
                } else {
                    Rectangle()
                        .fill(.red.opacity(0.3))
                        .frame(width: 24, height: 16)
                }
                Text(workspace.name)
                    .fontWeight(
                        workspaceStore.activeWorkspaceID == workspace.id ? .semibold : .regular
                    )
                Spacer()
                if let chord = workspace.hotkey {
                    hotkeyLabel(chord.displayString)
                }
            }
        }
        .buttonStyle(MenuRowButtonStyle())
        .disabled(coordinator.freeMode)
    }

    private func layoutRow(_ layout: CustomLayout) -> some View {
        let isActive = coordinator.activeLayoutID == layout.id
        return Button(action: { coordinator.applyLayout(layout) }) {
            HStack(spacing: 6) {
                LayoutThumbnail(layout: layout, size: CGSize(width: 24, height: 16))
                Text(layout.name)
                    .fontWeight(isActive ? .semibold : .regular)
                Spacer()
                if let h = layout.hotkey {
                    hotkeyLabel(h.displayString)
                }
                // Trailing tick for the layout applied most recently. Always
                // occupies its column so hotkey chords stay aligned whether or
                // not the row is ticked.
                checkmarkColumn(isActive)
            }
        }
        .buttonStyle(MenuRowButtonStyle())
        .disabled(coordinator.freeMode)
    }

    /// Cycles Off → Always → Timed → Off on each click, mirroring the
    /// segmented picker in Settings → Interaction so both stay in lockstep.
    private var stickyModeRow: some View {
        Button(action: { settingsVM.dragSwap.applying(nextStickyMode, to: settingsVM.store) }) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                    .foregroundStyle(settingsVM.dragSwap.stickyModeOption == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                Text("menu.section.stickiness")
                Spacer()
                Text(stickyModeValueLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(MenuRowButtonStyle())
        .disabled(coordinator.freeMode)
    }

    /// Two side-by-side on/off tiles for Spotlight (dim): "Dim" itself, and
    /// "Per monitor" (on = one app stays visible per monitor, off = one app
    /// globally). Per-monitor stays clickable while Dim is off so the choice
    /// is already made when Dim is turned back on.
    private var dimTilesRow: some View {
        let dim = settingsVM.spotlight
        return VStack(spacing: 6) {
            dimTile(
                dim.enabled ? "menu.dim.on" : "menu.dim.off",
                systemImage: "moon.fill",
                isOn: dim.enabled,
                help: "menu.dim.help",
                action: toggleDimEnabled
            )
            HStack(spacing: 6) {
                dimTile(
                    dim.exclusionMode == .perMonitor ? "menu.dim.mode.local" : "menu.dim.mode.global",
                    systemImage: "rectangle.on.rectangle",
                    isOn: dim.exclusionMode == .perMonitor,
                    help: "menu.dim.mode.help",
                    action: toggleDimPerMonitor
                )
                dimTile(
                    dim.dimBrowserChrome ? "menu.dim.tabs.on" : "menu.dim.tabs.off",
                    systemImage: "macwindow",
                    isOn: dim.dimBrowserChrome,
                    help: "menu.dim.tabs.help",
                    action: toggleDimBrowserTabs
                )
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    /// A tile's title says its CURRENT state (e.g. "Dim: On" / "Dim: Off"),
    /// and it is highlighted while that state is "on".
    private func dimTile(_ title: LocalizedStringKey, systemImage: String, isOn: Bool, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title).lineLimit(1)
            }
            .font(.callout)
            .fontWeight(isOn ? .semibold : .regular)
            .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var layoutsDisclosureRow: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { layoutsExpanded.toggle() } }) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(layoutsExpanded ? 90 : 0))
                    .frame(width: 14)
                Text("menu.section.layouts")
                Text("(\(layoutStore.layouts.count))")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    private func toggleDimEnabled() {
        var config = settingsVM.spotlight
        config.enabled.toggle()
        try? settingsVM.store.setSpotlight(config)
    }

    private func toggleDimBrowserTabs() {
        var config = settingsVM.spotlight
        config.dimBrowserChrome.toggle()
        try? settingsVM.store.setSpotlight(config)
    }

    private func toggleDimPerMonitor() {
        var config = settingsVM.spotlight
        config.exclusionMode = config.exclusionMode == .single ? .perMonitor : .single
        try? settingsVM.store.setSpotlight(config)
    }

    private var nextStickyMode: StickyModeOption {
        switch settingsVM.dragSwap.stickyModeOption {
        case .off: return .always
        case .always: return .timed
        case .timed: return .off
        }
    }

    private var stickyModeValueLabel: String {
        let cfg = settingsVM.dragSwap
        switch cfg.stickyModeOption {
        case .off:
            return String(localized: "interaction.drag_swap.mode.off")
        case .always:
            return String(localized: "interaction.drag_swap.mode.always")
        case .timed:
            let seconds = Int(cfg.autoDisableAfterSeconds ?? DragSwapConfig.defaultAutoDisableSeconds)
            let duration = String(format: String(localized: "interaction.drag_swap.mode.timed.duration.value"), seconds)
            return "\(String(localized: "interaction.drag_swap.mode.timed")) (\(duration))"
        }
    }

    // MARK: - Small pieces

    @ViewBuilder
    private func checkmarkColumn(_ on: Bool) -> some View {
        if on {
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
        } else {
            Spacer().frame(width: 14)
        }
    }

    private func hotkeyLabel(_ s: String) -> some View {
        Text(s)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 4)
    }

    private func closePanel() {
        panelWindow?.orderOut(nil)
    }

    /// Confirmation flow before kicking off the in-app installer (V0.5.6).
    /// Three-button NSAlert: **Install and Restart** (default), **Release
    /// Notes** (opens GitHub in browser like the pre-V0.5.6 behavior),
    /// **Later** (dismiss). When `dmgURL` is missing — an unusual GitHub
    /// release with no `.dmg` asset — we silently fall back to opening the
    /// release page so the user can still find the install path.
    private func handleUpdateClick(version: String, releaseURL: URL) {
        guard let dmgURL = updateChecker.dmgURL else {
            NSWorkspace.shared.open(releaseURL)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(
            format: String(localized: "update.install.alert.title"),
            version
        )
        alert.informativeText = String(localized: "update.install.alert.body")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "update.install.alert.install_and_restart"))
        alert.addButton(withTitle: String(localized: "update.install.alert.release_notes"))
        alert.addButton(withTitle: String(localized: "update.install.alert.later"))
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                await updateInstaller.install(dmgURL: dmgURL, version: version)
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(releaseURL)
        default:
            break
        }
    }

    private func activate(workspace: Workspace) {
        let id = workspace.id
        Task { @MainActor in
            await coordinator.applyWorkspace(id: id)
        }
    }
}

/// Grabs the NSWindow hosting the panel content so actions can dismiss it.
private struct PanelWindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { window = nsView.window }
    }
}

private struct PanelDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
    }
}
