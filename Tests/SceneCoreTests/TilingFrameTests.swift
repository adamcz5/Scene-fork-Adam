import XCTest
@testable import SceneCore

/// The Dock hops between displays with the mouse, so `NSScreen.visibleFrame`
/// reserves Dock space on a *different* screen depending on where the pointer
/// last went. `TilingFrame` unifies that reserve across every screen so the
/// tiling rect is a pure function of the display arrangement.
final class TilingFrameTests: XCTestCase {
    // Display A at the origin, 1000x1000, with a 25pt menu bar.
    private let frameA = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    // Display B to the right, same size, also carrying a menu bar
    // ("Displays have separate Spaces" — the macOS default).
    private let frameB = CGRect(x: 1000, y: 0, width: 1000, height: 1000)

    private let menuBar: CGFloat = 25
    private let dock: CGFloat = 70

    /// visibleFrame of a 1000x1000 screen with a menu bar and, optionally, the Dock.
    private func vf(_ frame: CGRect, dockAtBottom: Bool) -> CGRect {
        let bottom = dockAtBottom ? dock : 0
        return CGRect(
            x: frame.minX,
            y: frame.minY + bottom,
            width: frame.width,
            height: frame.height - menuBar - bottom
        )
    }

    private func insets(_ frame: CGRect, _ visible: CGRect) -> ScreenInsets {
        ScreenInsets(frame: frame, visibleFrame: visible)
    }

    // MARK: - Inset derivation

    func testInsetsDerivedFromFrameAndVisibleFrame() {
        let i = insets(frameA, vf(frameA, dockAtBottom: true))
        XCTAssertEqual(i.top, menuBar)
        XCTAssertEqual(i.bottom, dock)
        XCTAssertEqual(i.left, 0)
        XCTAssertEqual(i.right, 0)
    }

    func testInsetsClampNegativesToZero() {
        // A visibleFrame larger than its frame is nonsense, but AppKit has
        // reported odd geometry mid-display-reconfiguration before. Never let
        // a negative inset inflate the tiling rect past the physical screen.
        let oversized = frameA.insetBy(dx: -50, dy: -50)
        let i = insets(frameA, oversized)
        XCTAssertEqual(i, ScreenInsets(top: 0, left: 0, bottom: 0, right: 0))
    }

    // MARK: - Single display

    func testSingleScreenIsIdenticalToVisibleFrame() {
        // The whole point: single-display users must see zero behavior change.
        let visible = vf(frameA, dockAtBottom: true)
        let own = insets(frameA, visible)
        XCTAssertEqual(
            TilingFrame.compute(frame: frameA, ownInsets: own, allInsets: [own]),
            visible
        )
    }

    func testSingleScreenWithHiddenDockIsIdenticalToVisibleFrame() {
        let visible = vf(frameA, dockAtBottom: false)
        let own = insets(frameA, visible)
        XCTAssertEqual(
            TilingFrame.compute(frame: frameA, ownInsets: own, allInsets: [own]),
            visible
        )
    }

    // MARK: - The reported bug

    func testDockMovingBetweenDisplaysDoesNotChangeTheTilingFrame() {
        // Dock on A: A reserves it, B does not.
        let dockOnA = [
            insets(frameA, vf(frameA, dockAtBottom: true)),
            insets(frameB, vf(frameB, dockAtBottom: false)),
        ]
        // Dock hops to B: now B reserves it and A does not.
        let dockOnB = [
            insets(frameA, vf(frameA, dockAtBottom: false)),
            insets(frameB, vf(frameB, dockAtBottom: true)),
        ]

        let aWhileDockOnA = TilingFrame.compute(frame: frameA, ownInsets: dockOnA[0], allInsets: dockOnA)
        let aWhileDockOnB = TilingFrame.compute(frame: frameA, ownInsets: dockOnB[0], allInsets: dockOnB)
        XCTAssertEqual(aWhileDockOnA, aWhileDockOnB, "re-apply on A must target the same rect either way")

        let bWhileDockOnA = TilingFrame.compute(frame: frameB, ownInsets: dockOnA[1], allInsets: dockOnA)
        let bWhileDockOnB = TilingFrame.compute(frame: frameB, ownInsets: dockOnB[1], allInsets: dockOnB)
        XCTAssertEqual(bWhileDockOnA, bWhileDockOnB, "re-apply on B must target the same rect either way")
    }

    func testDocklessDisplayStillReservesDockSpace() {
        // This is the accepted trade-off — B gives up the Dock strip so that
        // the frame stops depending on where the pointer last went.
        let all = [
            insets(frameA, vf(frameA, dockAtBottom: true)),
            insets(frameB, vf(frameB, dockAtBottom: false)),
        ]
        let result = TilingFrame.compute(frame: frameB, ownInsets: all[1], allInsets: all)
        XCTAssertEqual(result, vf(frameB, dockAtBottom: true))
        XCTAssertNotEqual(result, vf(frameB, dockAtBottom: false))
    }

    // MARK: - Dock on a vertical edge

    func testLeftEdgeDockIsUnifiedHorizontally() {
        let visibleA = CGRect(x: 80, y: 0, width: 920, height: 975)   // Dock on the left of A
        let visibleB = CGRect(x: 1000, y: 0, width: 1000, height: 975)
        let all = [insets(frameA, visibleA), insets(frameB, visibleB)]

        let b = TilingFrame.compute(frame: frameB, ownInsets: all[1], allInsets: all)
        XCTAssertEqual(b, CGRect(x: 1080, y: 0, width: 920, height: 975))
    }

    func testRightEdgeDockIsUnifiedHorizontally() {
        let visibleA = CGRect(x: 0, y: 0, width: 920, height: 975)    // Dock on the right of A
        let visibleB = CGRect(x: 1000, y: 0, width: 1000, height: 975)
        let all = [insets(frameA, visibleA), insets(frameB, visibleB)]

        let b = TilingFrame.compute(frame: frameB, ownInsets: all[1], allInsets: all)
        XCTAssertEqual(b, CGRect(x: 1000, y: 0, width: 920, height: 975))
    }

    // MARK: - Menu bar stays per-screen

    func testTopInsetIsNotUnifiedAcrossScreens() {
        // The menu bar does not follow the mouse, so a screen without one must
        // not surrender 25pt just because another screen has one.
        let visibleA = vf(frameA, dockAtBottom: true)                     // 25pt menu bar
        let visibleB = CGRect(x: 1000, y: 0, width: 1000, height: 1000)   // no menu bar, no Dock
        let all = [insets(frameA, visibleA), insets(frameB, visibleB)]

        let b = TilingFrame.compute(frame: frameB, ownInsets: all[1], allInsets: all)
        XCTAssertEqual(b.maxY, frameB.maxY, "B has no menu bar — it keeps its top edge")
        XCTAssertEqual(b.minY, frameB.minY + dock, "B still reserves the shared Dock strip")
    }

    // MARK: - Degenerate arrangements

    func testDegenerateResultFallsBackToOwnVisibleFrame() {
        // A tiny external display next to one with insets big enough to consume it.
        let tiny = CGRect(x: 1000, y: 0, width: 60, height: 60)
        let tinyVisible = tiny
        let hoggish = ScreenInsets(top: 25, left: 200, bottom: 200, right: 200)
        let own = insets(tiny, tinyVisible)

        XCTAssertEqual(
            TilingFrame.compute(frame: tiny, ownInsets: own, allInsets: [hoggish, own]),
            tinyVisible
        )
    }

    func testEmptyInsetListFallsBackToOwnInsets() {
        let visible = vf(frameA, dockAtBottom: true)
        let own = insets(frameA, visible)
        XCTAssertEqual(
            TilingFrame.compute(frame: frameA, ownInsets: own, allInsets: []),
            visible
        )
    }

    // MARK: - Slot math is stationary across a Dock move

    func testQuadSlotRectsAreUnchangedWhenTheDockMoves() {
        // The end-to-end property the user reported: re-applying Quads on A
        // after the Dock hops to B must produce byte-identical slot rects, so
        // LayoutEngine's sticky pass matches and nothing visibly moves.
        let dockOnA = [
            insets(frameA, vf(frameA, dockAtBottom: true)),
            insets(frameB, vf(frameB, dockAtBottom: false)),
        ]
        let dockOnB = [
            insets(frameA, vf(frameA, dockAtBottom: false)),
            insets(frameB, vf(frameB, dockAtBottom: true)),
        ]

        let before = TilingFrame.compute(frame: frameA, ownInsets: dockOnA[0], allInsets: dockOnA)
        let after = TilingFrame.compute(frame: frameA, ownInsets: dockOnB[0], allInsets: dockOnB)

        let rectsBefore = Layout.quads.slots.map { $0.absoluteRect(in: before) }
        let rectsAfter = Layout.quads.slots.map { $0.absoluteRect(in: after) }
        XCTAssertEqual(rectsBefore, rectsAfter)
    }
}
