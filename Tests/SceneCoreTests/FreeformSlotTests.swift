import XCTest
@testable import SceneCore

final class FreeformSlotTests: XCTestCase {
    func testClampedLeavesInRangeRectUntouched() {
        let slot = FreeformSlot(rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        XCTAssertEqual(slot.clamped().rect, slot.rect)
    }

    func testClampedPullsOriginBackIntoUnitSquare() {
        let slot = FreeformSlot(rect: CGRect(x: -0.5, y: -0.5, width: 0.3, height: 0.3))
        let clamped = slot.clamped().rect
        XCTAssertEqual(clamped.minX, 0)
        XCTAssertEqual(clamped.minY, 0)
    }

    func testClampedCapsFarEdgeAtOne() {
        let slot = FreeformSlot(rect: CGRect(x: 0.5, y: 0.5, width: 2, height: 2))
        let clamped = slot.clamped().rect
        XCTAssertEqual(clamped.maxX, 1)
        XCTAssertEqual(clamped.maxY, 1)
    }

    func testClampedNeverProducesZeroOrNegativeSize() {
        // A degenerate drag where both edges cross past each other.
        let slot = FreeformSlot(rect: CGRect(x: 0.5, y: 0.5, width: -0.3, height: -0.3))
        let clamped = slot.clamped().rect
        XCTAssertGreaterThanOrEqual(clamped.width, FreeformSlot.minimumDimension)
        XCTAssertGreaterThanOrEqual(clamped.height, FreeformSlot.minimumDimension)
    }

    func testOverlappingSlotsAreNotRejected() {
        // The whole point of freeform slots: two rects covering the same area
        // are valid, unlike `Slot(safe:)`'s tiling invariant.
        let a = FreeformSlot(rect: CGRect(x: 0, y: 0, width: 0.3, height: 1))
        let b = FreeformSlot(rect: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9))
        XCTAssertEqual(a.clamped().rect, a.rect)
        XCTAssertEqual(b.clamped().rect, b.rect)
    }

    func testSlotConversionPreservesRect() {
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        XCTAssertEqual(FreeformSlot(rect: rect).slot.rect, rect)
    }
}
