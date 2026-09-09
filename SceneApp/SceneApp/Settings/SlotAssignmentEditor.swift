import SwiftUI
import AppKit
import SceneCore

/// Visual zone→app assignment editor. Renders the Workspace's layout as a
/// grid of tappable zones (same slot geometry as `LayoutThumbnail`, just
/// bigger and interactive); tapping a zone opens `SlotAppPickerSheet` to
/// assign/clear which app (optionally narrowed by a window-title hint, for
/// disambiguating e.g. two Chrome profiles) belongs there.
struct SlotAssignmentEditor: View {
    @Binding var slotAssignments: [WorkspaceSlotAssignment]
    let layout: CustomLayout?
    @State private var editingSlotIndex: Int?

    private var slots: [Slot] {
        layout?.toLayout().slots ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("workspace.editor.zones").font(.headline)
            if layout == nil {
                Text("workspace.editor.zones.no_layout")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    ZStack {
                        ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                            zoneButton(index: index, slot: slot, canvasSize: geo.size)
                        }
                    }
                }
                .frame(height: 140)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3)))
                Text("workspace.editor.zones.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: Binding(
            get: { editingSlotIndex != nil },
            set: { if !$0 { editingSlotIndex = nil } }
        )) {
            if let index = editingSlotIndex {
                SlotAppPickerSheet(
                    assignment: assignment(for: index),
                    onSave: { bundleID, titleContains in
                        setAssignment(slotIndex: index, bundleID: bundleID, titleContains: titleContains)
                    },
                    onClear: { clearAssignment(slotIndex: index) },
                    onCancel: { editingSlotIndex = nil }
                )
            }
        }
    }

    @ViewBuilder
    private func zoneButton(index: Int, slot: Slot, canvasSize: CGSize) -> some View {
        let rect = CGRect(
            x: slot.rect.minX * canvasSize.width,
            y: slot.rect.minY * canvasSize.height,
            width: slot.rect.width * canvasSize.width,
            height: slot.rect.height * canvasSize.height
        ).insetBy(dx: 2, dy: 2)
        let existing = assignment(for: index)
        Button(action: { editingSlotIndex = index }) {
            VStack(spacing: 4) {
                if let existing, let icon = appIcon(for: existing.bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                    Text(appName(for: existing.bundleID) ?? existing.bundleID)
                        .font(.caption2)
                        .lineLimit(1)
                    if let hint = existing.titleContains, !hint.isEmpty {
                        Text("\u{201C}\(hint)\u{201D}")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(existing == nil ? 0.12 : 0.25))
            )
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .position(x: rect.midX, y: rect.midY)
    }

    // MARK: - Mutation

    private func assignment(for slotIndex: Int) -> WorkspaceSlotAssignment? {
        slotAssignments.first(where: { $0.slotIndex == slotIndex })
    }

    private func setAssignment(slotIndex: Int, bundleID: String, titleContains: String?) {
        if let idx = slotAssignments.firstIndex(where: { $0.slotIndex == slotIndex }) {
            slotAssignments[idx].bundleID = bundleID
            slotAssignments[idx].titleContains = titleContains
        } else {
            slotAssignments.append(
                WorkspaceSlotAssignment(slotIndex: slotIndex, bundleID: bundleID, titleContains: titleContains)
            )
        }
        editingSlotIndex = nil
    }

    private func clearAssignment(slotIndex: Int) {
        slotAssignments.removeAll(where: { $0.slotIndex == slotIndex })
        editingSlotIndex = nil
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

/// Sheet for assigning one zone: pick an app (NSOpenPanel, same pattern as
/// `AppPickerView`) plus an optional "window title contains" hint used to
/// pick the right window when the app has several open — most commonly a
/// browser with multiple profiles/accounts signed into different windows.
private struct SlotAppPickerSheet: View {
    @State private var bundleID: String
    @State private var titleContains: String
    let onSave: (String, String?) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void

    init(
        assignment: WorkspaceSlotAssignment?,
        onSave: @escaping (String, String?) -> Void,
        onClear: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _bundleID = State(initialValue: assignment?.bundleID ?? "")
        _titleContains = State(initialValue: assignment?.titleContains ?? "")
        self.onSave = onSave
        self.onClear = onClear
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("workspace.editor.zones.assign_title").font(.headline)
            HStack {
                if let icon = appIcon(for: bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                }
                Text(bundleID.isEmpty
                     ? String(localized: "workspace.editor.zones.no_app")
                     : (appName(for: bundleID) ?? bundleID))
                    .foregroundStyle(bundleID.isEmpty ? .secondary : .primary)
                Spacer()
                Button("workspace.editor.zones.choose_app") { chooseApp() }
            }
            VStack(alignment: .leading, spacing: 2) {
                TextField("workspace.editor.zones.title_hint", text: $titleContains)
                Text("workspace.editor.zones.title_hint.caption")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("workspace.editor.zones.clear", role: .destructive) { onClear() }
                Spacer()
                Button("settings.action.cancel") { onCancel() }
                Button("common.done") {
                    onSave(bundleID, titleContains.isEmpty ? nil : titleContains)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bundleID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        bundleID = id
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func appName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }
}
