import Foundation

/// Binds a specific app to a specific zone of a Workspace's layout, so
/// activation places that app's window into that zone instead of whichever
/// slot the z-order fill pass would have given it.
///
/// `slotIndex` matches the order of `CustomLayout.toLayout().slots` (and thus
/// `Placement.slotIndex`) — stable as long as the referenced layout's zone
/// count/order isn't edited afterward. Not a UUID-per-slot design because
/// `Slot`/`LayoutNode` have no stable identity today; index-based matches how
/// the engine already tracks placements elsewhere (see `Plan.swift`).
public struct WorkspaceSlotAssignment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var slotIndex: Int
    /// e.g. "com.google.Chrome".
    public var bundleID: String
    /// Case-insensitive substring match against the window's title. Lets a
    /// user disambiguate two windows sharing one bundle ID — e.g. two Chrome
    /// profiles — by pinning "Work" to one zone and "Personal" to another.
    /// `nil` matches the first unclaimed window of `bundleID`.
    public var titleContains: String?

    public init(id: UUID = UUID(), slotIndex: Int, bundleID: String, titleContains: String? = nil) {
        self.id = id
        self.slotIndex = slotIndex
        self.bundleID = bundleID
        self.titleContains = titleContains
    }
}
