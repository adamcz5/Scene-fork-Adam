import CoreGraphics
import Foundation

/// A single window slot in a "freeform" (overlapping) layout — see
/// `CustomLayout.freeformSlots`. Unlike `LayoutNode`'s split-tree, a
/// `FreeformSlot`'s four edges move independently and slots are allowed to
/// overlap: there is no coverage/no-overlap invariant to maintain.
///
/// `rect` is in the same unit space as `Slot` (top-left origin, 0...1 on both
/// axes) so it materializes via the existing `Slot.absoluteRect(in:)` with no
/// engine changes.
///
/// Order matters: `CustomLayout.freeformSlots` is a plain array, and that
/// array order IS the initial z-order — `LayoutEngine.apply` raises windows
/// in slot-index order, so the last slot in the array ends up frontmost right
/// after the layout is applied. The editor's "Bring to Front" / "Send to
/// Back" actions just move a slot to the end / start of the array. After
/// that, normal macOS click-to-front behavior takes over — Scene never needs
/// to hit-test which window is "under" a click itself.
public struct FreeformSlot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var rect: CGRect

    public init(id: UUID = UUID(), rect: CGRect) {
        self.id = id
        self.rect = rect
    }

    /// Minimum width/height a slot may be clamped to. Not a design floor on
    /// the authored layout (freeform, like the split-tree editor, places no
    /// lower bound on how small a slot can be used) — purely a guard so a
    /// degenerate drag (both edges crossing) can't produce a zero/negative
    /// size that breaks `CGRect` math or SwiftUI layout.
    public static let minimumDimension: CGFloat = 0.02

    /// Clamps `rect` to the unit square without rejecting out-of-range input
    /// — the editor calls this on every live drag frame, so it must always
    /// return something renderable rather than throwing away the drag.
    public func clamped() -> FreeformSlot {
        let minX = min(max(rect.minX, 0), 1)
        let minY = min(max(rect.minY, 0), 1)
        let maxX = min(max(rect.maxX, minX + Self.minimumDimension), 1)
        let maxY = min(max(rect.maxY, minY + Self.minimumDimension), 1)
        return FreeformSlot(
            id: id,
            rect: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        )
    }

    /// Converts to the engine's `Slot` type. Always succeeds — `clamped()`
    /// already guarantees a positive, in-range rect.
    public var slot: Slot {
        Slot(rect: rect)
    }
}
