import SwiftUI
import AppKit

/// Classic-switcher-style row: one tile per candidate app, the current
/// selection picked out with a rounded highlight, a small "running" dot under
/// every icon (all candidates are, by construction, already-running apps —
/// see `AppSwitcherLogic.candidates`), and the selected app's name below the
/// row.
struct AppSwitcherHUDView: View {
    let candidates: [String]
    let selectedIndex: Int
    /// Windows of the currently-selected app, most-recent-ish order (as built
    /// by `AXWindowEnumerator`). Only rendered — as a HopTab-style list below
    /// the icon row — when there's more than one; a single-window app has
    /// nothing to drill into.
    let windowTitles: [String]
    let selectedWindowIndex: Int

    private let tileSize: CGFloat = 76
    private let iconSize: CGFloat = 56
    private let windowListWidth: CGFloat = 280

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                ForEach(Array(candidates.enumerated()), id: \.offset) { index, bundleID in
                    tile(bundleID: bundleID, isSelected: index == selectedIndex)
                }
            }
            if let name = selectedName {
                Text(name)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            if windowTitles.count > 1 {
                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: windowListWidth, height: 1)
                windowList
            }
        }
        .padding(28)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 20))
    }

    private var windowList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(windowTitles.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 8) {
                    Image(systemName: "macwindow")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(index == selectedWindowIndex ? Color.accentColor.opacity(0.55) : Color.clear)
                )
            }
        }
        .frame(width: windowListWidth)
    }

    private var selectedName: String? {
        guard candidates.indices.contains(selectedIndex) else { return nil }
        return appName(for: candidates[selectedIndex])
    }

    private func tile(bundleID: String, isSelected: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(0.18))
                        .frame(width: tileSize, height: tileSize)
                }
                if let icon = appIcon(for: bundleID) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: iconSize, height: iconSize)
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .frame(width: iconSize, height: iconSize)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: tileSize, height: tileSize)
            Circle()
                .fill(Color.green)
                .frame(width: 5, height: 5)
        }
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
