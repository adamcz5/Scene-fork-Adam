import SwiftUI
import AppKit
import SceneCore

/// Two-row panel shown by `WorkspacePickerWindowController`.
///
/// Row 1 ("Pinned"): Workspace tiles — layout + pre-assigned apps bundled
/// together, exactly as before. Click applies that Workspace outright.
/// Filtered to `Workspace.showInQuickPicker`.
///
/// Row 2 ("Layouts"): Layouts filtered to `CustomLayout.showInQuickPicker`
/// (toggled per-Layout from `LayoutEditorView`, mirroring the Workspace
/// flag). Clicking one shows the ⌥Tab app switcher's own configured entries
/// (`SettingsStoreViewModel.appSwitcher.entries`) as a row of icons; clicking
/// them IN ORDER assigns them left-to-right into the layout's zones — no
/// per-zone sheet, no confirm step. The instant enough icons are picked to
/// fill every zone, the layout applies automatically. (V0.10 history: this
/// briefly opened a `SlotAssignmentEditor` sheet per zone — got stuck open
/// over this panel's borderless `NSPanel` and was too many clicks anyway —
/// then briefly reverted to a blind instant-apply that couldn't target a
/// specific window/profile. This click-to-assign flow is the fix for both:
/// still one click per app, but ordered picks double as precise zone
/// assignments, including each entry's own `titleContains` for picking the
/// exact window/profile instead of whatever the z-order fill guesses.)
///
/// Both rows are fixed at 2 ROWS of tiles that scroll horizontally
/// (`LazyHGrid` in a `ScrollView(.horizontal)`) rather than a vertical grid
/// that grows taller with every Workspace/Layout added — a handful of tiles
/// used to make this panel absurdly tall.
struct WorkspaceQuickPickerView: View {
    @ObservedObject var workspaceStore: WorkspaceStoreViewModel
    @ObservedObject var layoutStore: LayoutStoreViewModel
    @ObservedObject var settingsVM: SettingsStoreViewModel
    let onSelect: (UUID) -> Void
    let onApplyLayout: (CustomLayout, [WorkspaceSlotAssignment]) -> Void
    let onDismiss: () -> Void

    /// Non-nil while Row 2 is showing the click-to-assign app row for this
    /// layout instead of the layout list.
    @State private var pickingLayout: CustomLayout?
    /// Entry IDs (not bundle IDs — two entries can share a bundle ID, e.g.
    /// "Personal"/"Work" Chrome) in the order they were clicked. Index i
    /// becomes zone i.
    @State private var pickedEntryIDs: [UUID] = []

    private var pickerWorkspaces: [Workspace] {
        workspaceStore.workspaces.filter { $0.showInQuickPicker }
    }

    private var pickerLayouts: [CustomLayout] {
        layoutStore.layouts.filter { $0.showInQuickPicker }
    }

    /// Fixed content width for the whole panel — rows below scroll
    /// horizontally within it rather than the panel growing to fit every
    /// tile, which is what made this panel "a tall huge column" before: a
    /// 2-column vertical grid grows one row taller for every 2 extra
    /// Workspaces/Layouts, with no cap.
    private let contentWidth: CGFloat = 360
    private let tileWidth: CGFloat = 84
    private let tileRowHeight: CGFloat = 78
    private let tileSpacing: CGFloat = 10
    // Fixed 2 ROWS (not columns) — tiles flow left-to-right, wrapping into a
    // new column after 2, and the row overflows into horizontal scroll
    // instead of the panel growing taller with every tile added.
    private var tileRows: [GridItem] {
        [GridItem(.fixed(tileRowHeight)), GridItem(.fixed(tileRowHeight))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            pinnedSection
            Divider()
            layoutSection
        }
        .padding(16)
        .frame(width: contentWidth + 32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .onExitCommand {
            // Esc backs out of app-picking mode first, mirroring the back
            // chevron, and only dismisses the whole panel on a second press.
            if pickingLayout != nil {
                cancelPicking()
            } else {
                onDismiss()
            }
        }
    }

    // MARK: - Row 1: Pinned Workspaces

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("workspace.picker.pinned_section")
                .font(.headline)
            if pickerWorkspaces.isEmpty {
                Text("workspace.picker.empty")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: tileRows, spacing: tileSpacing) {
                        ForEach(pickerWorkspaces) { workspace in
                            workspaceTile(for: workspace)
                        }
                    }
                }
                .frame(width: contentWidth, height: tileRowHeight * 2 + tileSpacing)
            }
        }
    }

    private func workspaceTile(for workspace: Workspace) -> some View {
        Button(action: { onSelect(workspace.id) }) {
            VStack(spacing: 4) {
                if let layout = layoutStore.layouts.first(where: { $0.id == workspace.layoutID }) {
                    LayoutThumbnail(layout: layout, size: CGSize(width: 56, height: 35))
                } else {
                    Rectangle()
                        .fill(.red.opacity(0.3))
                        .frame(width: 56, height: 35)
                }
                Text(workspace.name)
                    .font(.caption)
                    .lineLimit(1)
                if workspaceStore.activeWorkspaceID == workspace.id {
                    Label("workspace.picker.active", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .labelStyle(.iconOnly)
                }
            }
            .padding(6)
            .frame(width: tileWidth, height: tileRowHeight - tileSpacing)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(workspaceStore.activeWorkspaceID == workspace.id
                          ? Color.accentColor.opacity(0.15)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Row 2: Layouts / click-to-assign

    @ViewBuilder
    private var layoutSection: some View {
        if let layout = pickingLayout {
            appPickingSection(for: layout)
        } else {
            layoutListSection
        }
    }

    private var layoutListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("workspace.picker.layouts_section")
                .font(.headline)
            if pickerLayouts.isEmpty {
                Text("workspace.picker.layouts_empty")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: tileRows, spacing: tileSpacing) {
                        ForEach(pickerLayouts) { layout in
                            layoutTile(layout)
                        }
                    }
                }
                .frame(width: contentWidth, height: tileRowHeight * 2 + tileSpacing)
            }
        }
    }

    private func layoutTile(_ layout: CustomLayout) -> some View {
        Button(action: { beginPicking(layout) }) {
            VStack(spacing: 4) {
                LayoutThumbnail(layout: layout, size: CGSize(width: 56, height: 35))
                Text(layout.name)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(6)
            .frame(width: tileWidth, height: tileRowHeight - tileSpacing)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func beginPicking(_ layout: CustomLayout) {
        // Nothing configured to pick from — just apply blind (z-order fill),
        // same as before this feature existed, rather than showing a dead-end
        // empty picker.
        guard !settingsVM.appSwitcher.entries.isEmpty else {
            onApplyLayout(layout, [])
            return
        }
        pickedEntryIDs = []
        pickingLayout = layout
    }

    private func cancelPicking() {
        pickingLayout = nil
        pickedEntryIDs = []
    }

    private func appPickingSection(for layout: CustomLayout) -> some View {
        let slotCount = layout.toLayout().slots.count
        let entries = settingsVM.appSwitcher.entries
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: cancelPicking) {
                    Label("workspace.picker.back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
                Text(layout.name)
                    .font(.headline)
                Spacer()
                // Balances the back button so the title stays visually
                // centered instead of drifting toward the trailing edge.
                Label("workspace.picker.back", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .opacity(0)
            }
            Text(String(format: String(localized: "workspace.picker.pick_apps_hint"), pickedEntryIDs.count, slotCount))
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: tileRows, spacing: tileSpacing) {
                    ForEach(entries) { entry in
                        entryTile(entry, slotCount: slotCount)
                    }
                }
            }
            .frame(width: contentWidth, height: tileRowHeight * 2 + tileSpacing)
            // Escape valve for filling fewer zones than the layout has —
            // the common case (exactly enough picks) auto-applies below via
            // onChange, without ever needing this.
            Button(action: { applyPicked(layout: layout) }) {
                Text("workspace.picker.apply")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            .disabled(pickedEntryIDs.isEmpty)
        }
        .onChange(of: pickedEntryIDs) { _, picked in
            if picked.count >= slotCount { applyPicked(layout: layout) }
        }
    }

    private func entryTile(_ entry: AppSwitcherEntry, slotCount: Int) -> some View {
        let pickedOrder = pickedEntryIDs.firstIndex(of: entry.id)
        let isFull = pickedEntryIDs.count >= slotCount && pickedOrder == nil
        return Button(action: { toggle(entry) }) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 4) {
                    if let icon = appIcon(for: entry.bundleID) {
                        Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                    } else {
                        Image(systemName: "app.dashed")
                            .resizable()
                            .frame(width: 40, height: 40)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.label ?? appName(for: entry.bundleID) ?? entry.bundleID)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .opacity(isFull ? 0.35 : 1)
                if let order = pickedOrder {
                    Text("\(order + 1)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.accentColor))
                }
            }
            .padding(6)
            .frame(width: tileWidth, height: tileRowHeight - tileSpacing)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .disabled(isFull)
    }

    private func toggle(_ entry: AppSwitcherEntry) {
        if pickedEntryIDs.contains(entry.id) {
            pickedEntryIDs.removeAll { $0 == entry.id }
        } else {
            pickedEntryIDs.append(entry.id)
        }
    }

    private func applyPicked(layout: CustomLayout) {
        guard !pickedEntryIDs.isEmpty else { return }
        let entries = settingsVM.appSwitcher.entries
        let assignments = pickedEntryIDs.enumerated().compactMap { index, id -> WorkspaceSlotAssignment? in
            guard let entry = entries.first(where: { $0.id == id }) else { return nil }
            return WorkspaceSlotAssignment(slotIndex: index, bundleID: entry.bundleID, titleContains: entry.titleContains)
        }
        onApplyLayout(layout, assignments)
        cancelPicking()
    }

    // MARK: - NSWorkspace lookup

    private func appIcon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func appName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }
}
