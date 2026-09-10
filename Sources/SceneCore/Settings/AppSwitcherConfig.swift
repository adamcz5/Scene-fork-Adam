import Foundation

/// User-tunable settings for the V0.9 filtered app switcher (⌥Tab / ⌥⇧Tab) —
/// a HopTab-style replacement for macOS's per-app ⌘Tab that only cycles
/// through a short, user-chosen list of apps instead of every running app.
/// Persisted alongside `AnimationConfig`/`DragSwapConfig` in `SettingsStore`.
///
/// Deliberately does NOT touch ⌘Tab or require Accessibility permission —
/// see `AppSwitcherController`, which owns its own `HotkeyManager` instance
/// independent of `Coordinator`'s (which is gated behind AX permission for
/// window tiling).
public struct AppSwitcherConfig: Codable, Equatable, Sendable {
    public let enabled: Bool
    /// Ordered allow-list of bundle IDs, e.g. `["com.google.Chrome", ...]`.
    /// Cycle order follows this array's order, not most-recently-used — an
    /// explicit, user-controlled ring rather than a shifting one.
    public let bundleIDs: [String]

    /// `enabled: false` by default — there's nothing to cycle through until
    /// the user has picked at least one app in Settings, so it starts off
    /// rather than firing on an empty list.
    public static let `default` = AppSwitcherConfig(enabled: false, bundleIDs: [])

    public init(enabled: Bool, bundleIDs: [String]) {
        self.enabled = enabled
        self.bundleIDs = bundleIDs
    }
}
