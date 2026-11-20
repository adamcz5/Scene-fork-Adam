import AppKit
import SwiftUI

/// Small always-on-top window shown for the duration of `UpdateInstaller.install`.
/// Exists purely so the user has *something* visibly moving during the
/// download/verify/install phases — without it the app just goes idle for
/// however long that takes (several seconds on a slow connection), which
/// reads as "it's stuck" rather than "it's working".
@MainActor
final class UpdateProgressWindowController: NSWindowController {
    init(updateInstaller: UpdateInstaller) {
        let host = NSHostingController(
            rootView: UpdateProgressView().environmentObject(updateInstaller)
        )
        let window = NSPanel(contentViewController: host)
        window.styleMask = [.titled, .fullSizeContentView, .nonactivatingPanel]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for UpdateProgressWindowController")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct UpdateProgressView: View {
    @EnvironmentObject var updateInstaller: UpdateInstaller

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 28))
                .foregroundStyle(.tint)

            Text(updateInstaller.statusMessage ?? String(localized: "update.installer.installing"))
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let progress = updateInstaller.downloadProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text(String(format: String(localized: "update.installer.progress_percent"), Int(progress * 100)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Indeterminate bar for the verify/install phases (no byte
                // count to report there), instead of a circular spinner, so
                // it reads as a continuation of the same download bar above.
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 220)
            }
        }
        .padding(28)
        .frame(width: 280)
    }
}
