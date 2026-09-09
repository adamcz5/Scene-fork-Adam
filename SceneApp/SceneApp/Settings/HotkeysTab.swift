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
        }
        .alert("common.error", isPresented: .constant(errorMessage != nil)) {
            Button("common.ok") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
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
