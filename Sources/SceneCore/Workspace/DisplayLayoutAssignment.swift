import Foundation

/// Maps a display (by its user-visible name) to a specific layout — and,
/// optionally, to that display's own zone→app assignments.
/// Used in `Workspace.displayLayouts` to assign different layouts to different
/// connected screens when activating a Workspace.
public struct DisplayLayoutAssignment: Codable, Equatable, Hashable, Sendable {
    /// `NSScreen.localizedName` — consistent with `WorkspaceTrigger.monitorConnect`.
    public var displayName: String
    /// Foreign key referencing `CustomLayout.id` in `LayoutStore`.
    public var layoutID: UUID
    /// This display's own zone→app assignments, indexed against ITS layout's
    /// zones. `nil` means "none recorded for this display" — entries written
    /// before per-display assignments existed — and falls back to the
    /// workspace-wide `slotAssignments`. An empty array is a deliberate "no
    /// assignments on this display" and does NOT fall back.
    public var slotAssignments: [WorkspaceSlotAssignment]?

    public init(displayName: String, layoutID: UUID, slotAssignments: [WorkspaceSlotAssignment]? = nil) {
        self.displayName = displayName
        self.layoutID = layoutID
        self.slotAssignments = slotAssignments
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, layoutID, slotAssignments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.layoutID = try c.decode(UUID.self, forKey: .layoutID)
        self.slotAssignments = try c.decodeIfPresent([WorkspaceSlotAssignment].self, forKey: .slotAssignments)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(layoutID, forKey: .layoutID)
        try c.encodeIfPresent(slotAssignments, forKey: .slotAssignments)
    }
}
