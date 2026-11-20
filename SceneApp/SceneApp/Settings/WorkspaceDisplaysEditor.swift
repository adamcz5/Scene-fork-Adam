import AppKit
import SwiftUI
import SceneCore

/// "Displays & Layouts" for a Workspace: which layout each screen gets, and
/// which apps go in that layout's zones — all in one place.
///
/// Two modes, both on the existing data model (no schema break):
/// - **One layout** (`displayLayouts` empty): the workspace's primary
///   `layoutID` + `slotAssignments`, applied to the screen under the mouse.
/// - **Per display** (`displayLayouts` non-empty): one block per display, each
///   with its own layout and its own zone→app assignments
///   (`DisplayLayoutAssignment.slotAssignments`). The primary `layoutID` /
///   `slotAssignments` are kept in step with the first block so everything
///   that still reads them (menu thumbnails, displays not listed) stays sane.
struct WorkspaceDisplaysEditor: View {
    @Binding var draft: Workspace
    @ObservedObject var layoutStore: LayoutStoreViewModel

    private var isPerDisplay: Bool { !draft.displayLayouts.isEmpty }
    private var connectedNames: [String] { NSScreen.screens.map(\.localizedName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isPerDisplay {
                ForEach(Array(draft.displayLayouts.enumerated()), id: \.offset) { index, _ in
                    displayBlock(at: index)
                }
                HStack {
                    addDisplayMenu
                    Spacer()
                    Button("workspace.editor.displays.merge") { draft.displayLayouts = [] }
                        .controlSize(.small)
                }
            } else {
                singleBlock
                if connectedNames.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Button("workspace.editor.displays.split", action: splitPerDisplay)
                            .controlSize(.small)
                        Text("workspace.editor.displays.split.hint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: draft.displayLayouts) { _, _ in normalize() }
    }

    // MARK: - One layout

    private var singleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("workspace.editor.displays.single_hint")
                .font(.caption)
                .foregroundStyle(.secondary)
            LayoutPickerView(selectedID: $draft.layoutID, layoutStore: layoutStore)
            SlotAssignmentEditor(
                slotAssignments: $draft.slotAssignments,
                layout: layout(for: draft.layoutID)
            )
        }
    }

    // MARK: - Per display

    private func displayBlock(at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "display")
                Picker("", selection: displayNameBinding(index)) {
                    ForEach(nameChoices(for: index), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .fixedSize()
                if !connectedNames.contains(entry(at: index)?.displayName ?? "") {
                    Text("workspace.editor.displays.disconnected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    draft.displayLayouts.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("workspace.editor.displays.remove")
            }
            LayoutPickerView(selectedID: layoutBinding(index), layoutStore: layoutStore)
            SlotAssignmentEditor(
                slotAssignments: assignmentsBinding(index),
                layout: layout(for: entry(at: index)?.layoutID)
            )
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private var addDisplayMenu: some View {
        let used = Set(draft.displayLayouts.map(\.displayName))
        let available = connectedNames.filter { !used.contains($0) }
        return Menu {
            ForEach(available, id: \.self) { name in
                Button(name) {
                    draft.displayLayouts.append(
                        DisplayLayoutAssignment(displayName: name, layoutID: draft.layoutID, slotAssignments: [])
                    )
                }
            }
        } label: {
            Label("workspace.editor.displays.add", systemImage: "plus")
        }
        .controlSize(.small)
        .fixedSize()
        .disabled(available.isEmpty)
    }

    /// Starts per-display mode: one block per connected screen, each seeded
    /// with the current layout and zone assignments.
    private func splitPerDisplay() {
        draft.displayLayouts = connectedNames.map {
            DisplayLayoutAssignment(displayName: $0, layoutID: draft.layoutID, slotAssignments: draft.slotAssignments)
        }
    }

    // MARK: - Bindings

    private func entry(at index: Int) -> DisplayLayoutAssignment? {
        draft.displayLayouts.indices.contains(index) ? draft.displayLayouts[index] : nil
    }

    private func layout(for id: UUID?) -> CustomLayout? {
        guard let id else { return nil }
        return layoutStore.layouts.first(where: { $0.id == id })
    }

    /// Screens this block may pick: every connected one not used by another
    /// block, plus its own current name (which may be a disconnected screen).
    private func nameChoices(for index: Int) -> [String] {
        let others = Set(draft.displayLayouts.enumerated().filter { $0.offset != index }.map { $0.element.displayName })
        var names = connectedNames.filter { !others.contains($0) }
        if let current = entry(at: index)?.displayName, !names.contains(current) {
            names.append(current)
        }
        return names
    }

    private func displayNameBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { entry(at: index)?.displayName ?? "" },
            set: { name in
                guard draft.displayLayouts.indices.contains(index) else { return }
                draft.displayLayouts[index].displayName = name
            }
        )
    }

    private func layoutBinding(_ index: Int) -> Binding<UUID> {
        Binding(
            get: { entry(at: index)?.layoutID ?? draft.layoutID },
            set: { id in
                guard draft.displayLayouts.indices.contains(index) else { return }
                draft.displayLayouts[index].layoutID = id
            }
        )
    }

    /// An entry saved before per-display assignments existed has none of its
    /// own, so it SHOWS the workspace-wide list until the first edit writes one.
    private func assignmentsBinding(_ index: Int) -> Binding<[WorkspaceSlotAssignment]> {
        Binding(
            get: { entry(at: index)?.slotAssignments ?? draft.slotAssignments },
            set: { assignments in
                guard draft.displayLayouts.indices.contains(index) else { return }
                draft.displayLayouts[index].slotAssignments = assignments
            }
        )
    }

    // MARK: - Consistency

    /// Keeps the primary fields in step with the first block, and drops zone
    /// assignments that point past the end of a display's layout (switching to
    /// a layout with fewer zones). Only writes when something actually differs,
    /// so it settles after one pass instead of re-triggering itself.
    private func normalize() {
        guard let first = draft.displayLayouts.first else { return }
        if draft.layoutID != first.layoutID { draft.layoutID = first.layoutID }
        let primaryAssignments = first.slotAssignments ?? draft.slotAssignments
        if draft.slotAssignments != primaryAssignments { draft.slotAssignments = primaryAssignments }

        for index in draft.displayLayouts.indices {
            guard let assignments = draft.displayLayouts[index].slotAssignments,
                  let layout = layout(for: draft.displayLayouts[index].layoutID)
            else { continue }
            let zoneCount = layout.toLayout().slots.count
            let kept = assignments.filter { $0.slotIndex < zoneCount }
            if kept.count != assignments.count { draft.displayLayouts[index].slotAssignments = kept }
        }
    }
}
