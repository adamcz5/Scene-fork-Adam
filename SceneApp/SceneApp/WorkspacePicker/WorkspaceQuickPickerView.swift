import SwiftUI
import SceneCore

/// Grid of clickable Workspace tiles shown by `WorkspacePickerWindowController`.
/// Only Workspaces with `showInQuickPicker == true` appear — toggled per-
/// Workspace from `WorkspaceEditorView`. Click applies it; Escape or a click
/// outside the panel dismisses without action.
struct WorkspaceQuickPickerView: View {
    @ObservedObject var workspaceStore: WorkspaceStoreViewModel
    @ObservedObject var layoutStore: LayoutStoreViewModel
    let onSelect: (UUID) -> Void
    let onDismiss: () -> Void

    private var pickerWorkspaces: [Workspace] {
        workspaceStore.workspaces.filter { $0.showInQuickPicker }
    }

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 140), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("workspace.picker.title")
                .font(.headline)
            if pickerWorkspaces.isEmpty {
                Text("workspace.picker.empty")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(pickerWorkspaces) { workspace in
                            tile(for: workspace)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .onExitCommand { onDismiss() }
    }

    private func tile(for workspace: Workspace) -> some View {
        Button(action: { onSelect(workspace.id) }) {
            VStack(spacing: 6) {
                if let layout = layoutStore.layouts.first(where: { $0.id == workspace.layoutID }) {
                    LayoutThumbnail(layout: layout, size: CGSize(width: 96, height: 60))
                } else {
                    Rectangle()
                        .fill(.red.opacity(0.3))
                        .frame(width: 96, height: 60)
                }
                Text(workspace.name)
                    .font(.callout)
                    .lineLimit(1)
                if workspaceStore.activeWorkspaceID == workspace.id {
                    Label("workspace.picker.active", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .labelStyle(.iconOnly)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(workspaceStore.activeWorkspaceID == workspace.id
                          ? Color.accentColor.opacity(0.15)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}
