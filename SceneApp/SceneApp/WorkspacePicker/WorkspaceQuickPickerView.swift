import SwiftUI
import SceneCore

/// Two-row panel shown by `WorkspacePickerWindowController`.
///
/// Row 1 ("Pinned"): Workspace tiles — layout + pre-assigned apps bundled
/// together, exactly as before. Click applies that Workspace outright.
/// Filtered to `Workspace.showInQuickPicker`.
///
/// Row 2 ("Layouts"): Layouts filtered to `CustomLayout.showInQuickPicker`
/// (toggled per-Layout from `LayoutEditorView`, mirroring the Workspace
/// flag), with no apps attached. Clicking one applies it immediately —
/// z-order/sticky-fills whatever's currently open, exactly like clicking a
/// layout in the menu bar. (V0.10: this used to open a per-zone
/// app-assignment editor first — reusing `SlotAssignmentEditor` — but a
/// `.sheet()` presented over this panel's borderless `NSPanel` didn't
/// reliably dismiss, and the extra step was more friction than a quick-switch
/// tool should have anyway. Reverted to instant-apply.)
///
/// Both rows are fixed at 2 ROWS of tiles that scroll horizontally
/// (`LazyHGrid` in a `ScrollView(.horizontal)`) rather than a vertical grid
/// that grows taller with every Workspace/Layout added — a handful of tiles
/// used to make this panel absurdly tall.
struct WorkspaceQuickPickerView: View {
    @ObservedObject var workspaceStore: WorkspaceStoreViewModel
    @ObservedObject var layoutStore: LayoutStoreViewModel
    let onSelect: (UUID) -> Void
    let onApplyLayout: (CustomLayout, [WorkspaceSlotAssignment]) -> Void
    let onDismiss: () -> Void

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
        .onExitCommand { onDismiss() }
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

    // MARK: - Row 2: Layouts

    private var layoutSection: some View {
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
        // Apply immediately — no per-zone assignment step. `onApplyLayout`
        // with empty assignments falls through to the engine's normal
        // z-order/sticky fill of whatever's currently open, same as a
        // menu-bar or hotkey layout fire.
        Button(action: { onApplyLayout(layout, []) }) {
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
}
