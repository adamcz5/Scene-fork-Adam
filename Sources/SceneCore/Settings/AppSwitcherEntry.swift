import Foundation

/// One tile in the ⌥Tab app switcher's ring. Usually just "this app" (one
/// entry per bundle ID, like V0.9's original flat `bundleIDs` list), but an
/// app can appear as MULTIPLE entries — e.g. two separate Chrome tiles for
/// "Personal" vs "Work" — disambiguated by `titleContains`, the same
/// window-title-matching convention `WorkspaceSlotAssignment` already uses to
/// tell two Chrome profiles apart for zone assignment.
public struct AppSwitcherEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var bundleID: String
    /// `nil` matches any window of this app — the plain, single-tile case.
    /// Non-nil narrows this entry to windows whose title contains this text
    /// (case-insensitive), both for deciding whether the entry is "running"
    /// right now and for which specific window gets raised on selection.
    /// Requires Accessibility permission to evaluate (reading window titles);
    /// an entry with a filter set is simply skipped — not shown, not
    /// selectable — when AX isn't granted, rather than guessing.
    public var titleContains: String?
    /// Overrides the app's own display name in the switcher HUD when set —
    /// e.g. "Work" instead of "Google Chrome" for a title-filtered entry.
    public var label: String?
    /// Hex string like `"#4C8BF5"`. A user-picked outline drawn around this
    /// entry's icon tile in the HUD, so two otherwise-identical app icons
    /// (two Chrome tiles) stay visually distinguishable at a glance. `nil` —
    /// the default — draws no outline, unchanged from V0.9's appearance.
    public var colorHex: String?

    public init(
        id: UUID = UUID(),
        bundleID: String,
        titleContains: String? = nil,
        label: String? = nil,
        colorHex: String? = nil
    ) {
        self.id = id
        self.bundleID = bundleID
        self.titleContains = titleContains
        self.label = label
        self.colorHex = colorHex
    }
}
