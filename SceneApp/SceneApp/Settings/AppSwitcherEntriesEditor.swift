import AppKit
import SwiftUI
import SceneCore
import UniformTypeIdentifiers

/// Editor for the ⌥Tab app switcher's ring — like `AppPickerView` (same
/// NSOpenPanel app-choosing pattern) but one entry can carry an optional
/// window-title filter, display label, and outline color, so the same app
/// can appear as more than one tile (e.g. "Personal" / "Work" Chrome,
/// disambiguated by window title exactly like `WorkspaceSlotAssignment`
/// already does for zone assignment).
struct AppSwitcherEntriesEditor: View {
    @Binding var entries: [AppSwitcherEntry]
    @State private var editingEntry: AppSwitcherEntry?
    @State private var isAddingNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("interaction.app_switcher.apps").font(.headline)
                Spacer()
                Button("workspace.editor.apps.add") { isAddingNew = true }
            }
            List {
                ForEach(entries) { entry in
                    row(for: entry)
                }
            }
            .frame(minHeight: 80, maxHeight: 160)
        }
        .sheet(item: $editingEntry) { entry in
            AppSwitcherEntrySheet(
                entry: entry,
                onSave: { updated in
                    if let idx = entries.firstIndex(where: { $0.id == updated.id }) {
                        entries[idx] = updated
                    }
                    editingEntry = nil
                },
                onRemove: {
                    entries.removeAll { $0.id == entry.id }
                    editingEntry = nil
                },
                onCancel: { editingEntry = nil }
            )
        }
        .sheet(isPresented: $isAddingNew) {
            AppSwitcherEntrySheet(
                entry: nil,
                onSave: { new in
                    entries.append(new)
                    isAddingNew = false
                },
                onRemove: { isAddingNew = false },
                onCancel: { isAddingNew = false }
            )
        }
    }

    private func row(for entry: AppSwitcherEntry) -> some View {
        Button(action: { editingEntry = entry }) {
            HStack {
                if let icon = appIcon(for: entry.bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: "app.dashed")
                        .frame(width: 16, height: 16)
                        .foregroundStyle(.secondary)
                }
                if let hex = entry.colorHex, let color = Color(hex: hex) {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text(entry.label ?? appName(for: entry.bundleID) ?? entry.bundleID)
                if let filter = entry.titleContains, !filter.isEmpty {
                    Text("\u{201C}\(filter)\u{201D}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { entries.removeAll { $0.id == entry.id } }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("workspace.editor.apps.remove")
            }
        }
        .buttonStyle(.plain)
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func appName(for bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }
}

/// Add/edit sheet for one entry: pick an app, optionally label it, optionally
/// narrow it to windows whose title contains some text, optionally give it an
/// outline color. `entry == nil` means "adding a new one".
private struct AppSwitcherEntrySheet: View {
    @State private var bundleID: String
    @State private var label: String
    @State private var titleContains: String
    @State private var useCustomColor: Bool
    @State private var color: Color

    let originalID: UUID?
    let onSave: (AppSwitcherEntry) -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void

    init(
        entry: AppSwitcherEntry?,
        onSave: @escaping (AppSwitcherEntry) -> Void,
        onRemove: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _bundleID = State(initialValue: entry?.bundleID ?? "")
        _label = State(initialValue: entry?.label ?? "")
        _titleContains = State(initialValue: entry?.titleContains ?? "")
        let existingColor = entry?.colorHex.flatMap(Color.init(hex:))
        _useCustomColor = State(initialValue: existingColor != nil)
        _color = State(initialValue: existingColor ?? .accentColor)
        self.originalID = entry?.id
        self.onSave = onSave
        self.onRemove = onRemove
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("interaction.app_switcher.entry.title").font(.headline)
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
            TextField("interaction.app_switcher.entry.label", text: $label)
            VStack(alignment: .leading, spacing: 2) {
                TextField("workspace.editor.zones.title_hint", text: $titleContains)
                Text("interaction.app_switcher.entry.title_hint.caption")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("interaction.app_switcher.entry.custom_color", isOn: $useCustomColor)
            if useCustomColor {
                ColorPicker("interaction.app_switcher.entry.color", selection: $color, supportsOpacity: false)
            }
            HStack {
                if originalID != nil {
                    Button("workspace.editor.zones.clear", role: .destructive, action: onRemove)
                }
                Spacer()
                Button("settings.action.cancel", action: onCancel)
                Button("common.done") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(bundleID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func save() {
        onSave(AppSwitcherEntry(
            id: originalID ?? UUID(),
            bundleID: bundleID,
            titleContains: titleContains.isEmpty ? nil : titleContains,
            label: label.isEmpty ? nil : label,
            colorHex: useCustomColor ? color.toHex() : nil
        ))
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

extension Color {
    /// Best-effort round trip back to `"#RRGGBB"` for persistence. Resolves
    /// via `NSColor` in the sRGB space; a color the system can't resolve that
    /// way (rare) falls back to `nil`, leaving the entry with no outline
    /// rather than persisting a wrong one.
    func toHex() -> String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
