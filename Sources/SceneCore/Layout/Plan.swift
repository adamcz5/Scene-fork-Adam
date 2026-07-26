import CoreGraphics

public struct Placement: Sendable, Equatable {
    public let windowID: CGWindowID
    public let targetFrame: CGRect
    /// Index into `layout.slots` this placement fills. Defaults to 0 for
    /// ad-hoc single-window placements (drag-swap return animation) where
    /// slot identity is irrelevant.
    public let slotIndex: Int

    public init(windowID: CGWindowID, targetFrame: CGRect, slotIndex: Int = 0) {
        self.windowID = windowID
        self.targetFrame = targetFrame
        self.slotIndex = slotIndex
    }
}

public struct Plan: Sendable, Equatable {
    public let placements: [Placement]
    public let toMinimize: [CGWindowID]
    public let leftEmptySlotCount: Int

    public init(placements: [Placement], toMinimize: [CGWindowID], leftEmptySlotCount: Int) {
        self.placements = placements
        self.toMinimize = toMinimize
        self.leftEmptySlotCount = leftEmptySlotCount
    }

    public var isEmpty: Bool { placements.isEmpty && toMinimize.isEmpty }
}

public enum Outcome: Sendable, Equatable {
    case applied(placed: Int, minimized: Int, leftEmpty: Int, failed: Int)
    case noWindows
}
