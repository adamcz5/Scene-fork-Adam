import SwiftUI
import SceneCore

struct HotkeysTab: View {
    @EnvironmentObject var layoutVM: LayoutStoreViewModel
    @EnvironmentObject var workspaceVM: WorkspaceStoreViewModel
    @EnvironmentObject var settingsVM: SettingsStoreViewModel
    @State private var recordingForID: UUID?
    @State private var recordingQuickPicker: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("hotkeys.section.quick_picker") {
                HStack {
                    Text("hotkeys.quick_picker.label").frame(width: 180, alignment: .leading)
                    if recordingQuickPicker {
                        HotkeyCaptureView { binding in
                            attemptQuickPicker(binding: binding)
                        }
                        .frame(height: 28)
                    } else {
                        Text(settingsVM.quickPickerHotkey?.displayString ?? "\u{2014}")
                            .frame(width: 100, alignment: .leading)
                            .foregroundStyle(settingsVM.quickPickerHotkey == nil ? .secondary : .primary)
                    }
                    Spacer()
                    Button(recordingQuickPicker
                           ? LocalizedStringKey("settings.action.cancel")
                           : LocalizedStringKey("hotkeys.record")) {
                        recordingQuickPicker.toggle()
                    }
                    Button("hotkeys.clear") {
                        try? settingsVM.setQuickPickerHotkey(nil)
                    }
                    .disabled(settingsVM.quickPickerHotkey == nil)
                }
                .padding(.vertical, 2)
                Text("hotkeys.quick_picker.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("hotkeys.section.dim") {
                HotkeyField(
                    chord: dimHotkeyBinding,
                    label: "interaction.spotlight.hotkey",
                    validate: validateDimHotkey
                )
                Text("interaction.spotlight.hotkey.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("hotkeys.section.layouts") {
                ForEach(layoutVM.layouts) { layout in
                    HStack {
                        Text(layout.name).frame(width: 180, alignment: .leading)
                        if recordingForID == layout.id {
                            HotkeyCaptureView { binding in
                                attempt(binding: binding, on: layout)
                            }
                            .frame(height: 28)
                        } else {
                            Text(layout.hotkey?.displayString ?? "\u{2014}")
                                .frame(width: 100, alignment: .leading)
                                .foregroundStyle(layout.hotkey == nil ? .secondary : .primary)
                        }
                        Spacer()
                        Button(recordingForID == layout.id
                               ? LocalizedStringKey("settings.action.cancel")
                               : LocalizedStringKey("hotkeys.record")) {
                            recordingForID = (recordingForID == layout.id ? nil : layout.id)
                        }
                        Button("hotkeys.clear") {
                            var copy = layout
                            copy.hotkey = nil
                            do { try layoutVM.store.update(copy) }
                            catch { errorMessage = String(describing: error) }
                        }
                        .disabled(layout.hotkey == nil)
                    }
                    .padding(.vertical, 2)
                }
            }
            if !workspaceVM.workspaces.isEmpty {
                Section("hotkeys.section.focus") {
                    Text("hotkeys.focus.hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(workspaceVM.workspaces) { workspace in
                        WorkspaceFocusShortcutsRow(workspace: workspace) { updated in
                            do { try workspaceVM.update(updated) }
                            catch { errorMessage = String(describing: error) }
                        }
                    }
                }
            }
        }
        .alert("common.error", isPresented: .constant(errorMessage != nil)) {
            Button("common.ok") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var dimHotkeyBinding: Binding<HotkeyBinding?> {
        Binding(
            get: { settingsVM.spotlight.hotkey },
            set: { value in
                var config = settingsVM.spotlight
                config.hotkey = value
                try? settingsVM.store.setSpotlight(config)
            }
        )
    }

    /// Same cross-check as the Quick Picker: refuse a chord already bound to a
    /// layout, a workspace, or the Quick Picker.
    private func validateDimHotkey(_ binding: HotkeyBinding) -> String? {
        let format = String(localized: "hotkeys.conflict")
        if let layout = layoutVM.layouts.first(where: { $0.hotkey == binding }) {
            return String(format: format, layout.name)
        }
        if let workspace = workspaceVM.workspaces.first(where: { $0.hotkey == binding }) {
            return String(format: format, workspace.name)
        }
        if settingsVM.quickPickerHotkey == binding {
            return String(format: format, String(localized: "hotkeys.quick_picker.label"))
        }
        return nil
    }

    private func attempt(binding: HotkeyBinding, on layout: CustomLayout) {
        var copy = layout
        copy.hotkey = binding
        do {
            try layoutVM.store.update(copy)
            recordingForID = nil
        } catch let LayoutStoreError.hotkeyConflict(existingResource) {
            errorMessage = String(format: String(localized: "hotkeys.conflict"), existingResource)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Settings' hotkey isn't behind either store's own conflict probe (those
    /// only cross-check each other — see `AppDelegate.setHotkeyConflictProbe`),
    /// so check both lists here before saving.
    private func attemptQuickPicker(binding: HotkeyBinding) {
        if let existing = layoutVM.layouts.first(where: { $0.hotkey == binding }) {
            errorMessage = String(format: String(localized: "hotkeys.conflict"), existing.name)
            return
        }
        if let existing = workspaceVM.workspaces.first(where: { $0.hotkey == binding }) {
            errorMessage = String(format: String(localized: "hotkeys.conflict"), existing.name)
            return
        }
        do {
            try settingsVM.setQuickPickerHotkey(binding)
            recordingQuickPicker = false
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

/// One workspace's macOS Shortcuts hooks: the Shortcut that runs when the
/// workspace turns on, and the one that runs when it turns off (typically a
/// Focus / Do Not Disturb toggle). Edited as text and saved when a field is
/// submitted or loses focus — not on every keystroke, since each save writes
/// the workspace store.
private struct WorkspaceFocusShortcutsRow: View {
    let workspace: Workspace
    let onSave: (Workspace) -> Void

    @State private var on: String
    @State private var off: String
    @FocusState private var focused: Field?

    private enum Field { case on, off }

    init(workspace: Workspace, onSave: @escaping (Workspace) -> Void) {
        self.workspace = workspace
        self.onSave = onSave
        _on = State(initialValue: workspace.focusMode?.shortcutNameOn ?? "")
        _off = State(initialValue: workspace.focusMode?.shortcutNameOff ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(workspace.name).font(.callout).bold()
            TextField("workspace.editor.focus.shortcut_on", text: $on)
                .focused($focused, equals: .on)
                .onSubmit(commit)
            TextField("workspace.editor.focus.shortcut_off", text: $off)
                .focused($focused, equals: .off)
                .onSubmit(commit)
        }
        .padding(.vertical, 2)
        .onChange(of: focused) { _, newValue in
            if newValue == nil { commit() }
        }
    }

    private func commit() {
        var updated = workspace
        var reference = updated.focusMode ?? FocusModeReference()
        reference.shortcutNameOn = on.isEmpty ? nil : on
        reference.shortcutNameOff = off.isEmpty ? nil : off
        updated.focusMode = (reference.shortcutNameOn == nil && reference.shortcutNameOff == nil) ? nil : reference
        guard updated != workspace else { return }
        onSave(updated)
    }
}
