import Foundation

/// User-tunable settings for the V0.9 filtered app switcher (⌥Tab / ⌥⇧Tab) —
/// a HopTab-style replacement for macOS's per-app ⌘Tab that only cycles
/// through a short, user-chosen list of apps instead of every running app.
/// Persisted alongside `AnimationConfig`/`DragSwapConfig` in `SettingsStore`.
///
/// Deliberately does NOT touch ⌘Tab or require Accessibility permission —
/// see `AppSwitcherController`, which owns its own `HotkeyManager` instance
/// independent of `Coordinator`'s (which is gated behind AX permission for
/// window tiling). AX IS needed for `AppSwitcherEntry.titleContains`
/// filtering and for the per-window drill-down, both of which degrade
/// gracefully without it.
public struct AppSwitcherConfig: Codable, Equatable, Sendable {
    public let enabled: Bool
    /// The ring's tiles. Order is display/config order, not most-recently-used
    /// — `AppSwitcherLogic` reorders by MRU at cycle time; this is just the
    /// user-controlled allow-list. Usually one entry per app, but the same
    /// `bundleID` can appear more than once (e.g. two Chrome entries split by
    /// `titleContains` into "Personal" vs "Work").
    public let entries: [AppSwitcherEntry]

    /// Read-only convenience for callers that only care about plain app
    /// membership (not per-entry label/color/title-filter) — e.g. checking
    /// "is the ring configured at all". Not necessarily unique: two entries
    /// for the same app (different `titleContains`) both contribute their
    /// shared bundle ID.
    public var bundleIDs: [String] { entries.map(\.bundleID) }

    /// `enabled: false` by default — there's nothing to cycle through until
    /// the user has picked at least one app in Settings, so it starts off
    /// rather than firing on an empty list.
    public static let `default` = AppSwitcherConfig(enabled: false, entries: [])

    public init(enabled: Bool, entries: [AppSwitcherEntry]) {
        self.enabled = enabled
        self.entries = entries
    }

    /// Convenience for the common case (and for pre-V0.10 call sites/tests):
    /// one plain entry per bundle ID, no label/color/title-filter.
    public init(enabled: Bool, bundleIDs: [String]) {
        self.init(enabled: enabled, entries: bundleIDs.map { AppSwitcherEntry(bundleID: $0) })
    }

    // MARK: - Codable (backward-compatible with the V0.9 flat `bundleIDs` schema)

    private enum CodingKeys: String, CodingKey { case enabled, entries, bundleIDs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = try c.decode(Bool.self, forKey: .enabled)
        if let entries = try c.decodeIfPresent([AppSwitcherEntry].self, forKey: .entries) {
            self.init(enabled: enabled, entries: entries)
        } else {
            // Pre-V0.10 file: flat `bundleIDs`, no entries. Absent entirely
            // (not just empty) on a fresh V0.9 install too, hence `?? []`.
            let bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
            self.init(enabled: enabled, bundleIDs: bundleIDs)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(entries, forKey: .entries)
    }
}
