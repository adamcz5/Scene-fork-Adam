import AppKit
import SwiftUI

/// "About Scene" tab — version + project link + re-open welcome screen
/// action + V0.6 diagnostic toggle + export + V0.10 manual update check.
struct AboutTab: View {
    var reopenWelcome: () -> Void
    var exportDiagnostics: () async -> Void

    @EnvironmentObject var settingsVM: SettingsStoreViewModel
    @EnvironmentObject var updateChecker: UpdateChecker
    @EnvironmentObject var updateInstaller: UpdateInstaller

    @State private var exporting = false
    @State private var showDisableConfirm = false
    @State private var isCheckingForUpdate = false
    /// Set right after a manual check completes so "You're up to date" only
    /// shows once we've actually asked GitHub this session — before that,
    /// staying silent is more honest than guessing.
    @State private var hasCheckedThisSession = false

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("about.app_name")
                .font(.largeTitle)
                .bold()
            Text(verbatim: "V\(currentVersion)")
                .foregroundStyle(.secondary)
            Text("about.description")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Link(
                "github.com/adamcz5/Scene-fork-Adam",
                destination: URL(string: "https://github.com/adamcz5/Scene-fork-Adam")!
            )

            Divider().padding(.vertical, 8)

            Button(String(localized: "about.welcome.reopen")) {
                reopenWelcome()
            }
            .controlSize(.small)

            Divider().padding(.vertical, 8)

            updatesSection

            Divider().padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("about.diagnostics.section.title")
                    .font(.headline)
                Toggle(isOn: Binding(
                    get: { settingsVM.diagnosticsEnabled },
                    set: { newValue in
                        if newValue {
                            Task { await settingsVM.setDiagnosticsEnabled(true) }
                        } else {
                            showDisableConfirm = true
                        }
                    }
                )) {
                    Text("about.diagnostics.toggle")
                }
                Text("about.diagnostics.toggle.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    guard !exporting else { return }
                    exporting = true
                    Task {
                        await exportDiagnostics()
                        exporting = false
                    }
                } label: {
                    if exporting {
                        Text("about.diagnostics.export.exporting")
                    } else {
                        Text("about.diagnostics.export.button")
                    }
                }
                .controlSize(.small)
                .disabled(exporting || !settingsVM.diagnosticsEnabled)
                if !settingsVM.diagnosticsEnabled {
                    Text("about.diagnostics.export.disabled.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .confirmationDialog(
            String(localized: "about.diagnostics.confirm.disable.title"),
            isPresented: $showDisableConfirm
        ) {
            Button(String(localized: "about.diagnostics.confirm.disable.ok"), role: .destructive) {
                Task { await settingsVM.setDiagnosticsEnabled(false) }
            }
            Button(String(localized: "about.diagnostics.confirm.disable.cancel"), role: .cancel) {}
        } message: {
            Text("about.diagnostics.confirm.disable.body")
        }
    }

    // MARK: - Updates

    @ViewBuilder
    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("about.updates.section.title")
                .font(.headline)

            if let version = updateChecker.availableVersion {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.tint)
                    Text(String(format: String(localized: "about.updates.available"), version))
                }
                Button(String(localized: "update.install.alert.install_and_restart")) {
                    handleInstall(version: version)
                }
                .controlSize(.small)
            } else if hasCheckedThisSession {
                Text(String(format: String(localized: "about.updates.up_to_date"), currentVersion))
                    .foregroundStyle(.secondary)
            }

            Button {
                guard !isCheckingForUpdate else { return }
                isCheckingForUpdate = true
                updateChecker.forceCheck()
                // UpdateChecker's check is fire-and-forget with no completion
                // callback (menu bar banner just reacts to @Published state
                // whenever it lands) — this fixed delay is long enough for
                // the GitHub API round trip in practice without adding a
                // completion handler to a type shared with the menu bar.
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    isCheckingForUpdate = false
                    hasCheckedThisSession = true
                }
            } label: {
                if isCheckingForUpdate {
                    Text("about.updates.checking")
                } else {
                    Text("about.updates.check_button")
                }
            }
            .controlSize(.small)
            .disabled(isCheckingForUpdate)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxWidth: 420)
    }

    /// Mirrors `MenuBarContentView.handleUpdateClick` — same three-button
    /// confirmation (Install and Restart / Release Notes / Later).
    private func handleInstall(version: String) {
        guard let dmgURL = updateChecker.dmgURL else {
            if let url = updateChecker.releasePageURL { NSWorkspace.shared.open(url) }
            return
        }
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "update.install.alert.title"), version)
        alert.informativeText = String(localized: "update.install.alert.body")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "update.install.alert.install_and_restart"))
        alert.addButton(withTitle: String(localized: "update.install.alert.release_notes"))
        alert.addButton(withTitle: String(localized: "update.install.alert.later"))
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            Task { @MainActor in await updateInstaller.install(dmgURL: dmgURL, version: version) }
        case .alertSecondButtonReturn:
            if let url = updateChecker.releasePageURL { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }
}
