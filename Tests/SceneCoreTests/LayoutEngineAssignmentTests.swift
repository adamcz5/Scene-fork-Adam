import XCTest
@testable import SceneCore

final class LayoutEngineAssignmentTests: XCTestCase {
    let vf = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    func testAssignmentWinsOverZOrder() {
        // Without an assignment, z-order fill would put `front` in slot 0.
        // With an assignment pinning `back`'s bundle ID to slot 0, it should
        // win instead.
        let front = MockWindow(id: 1, bundleID: "com.example.front")
        let back = MockWindow(id: 2, bundleID: "com.example.back")
        let plan = LayoutEngine.plan(
            windows: [front, back],
            visibleFrame: vf,
            layout: .halves,
            assignments: [WorkspaceSlotAssignment(slotIndex: 0, bundleID: "com.example.back")]
        )
        XCTAssertEqual(plan.placements.first(where: { $0.slotIndex == 0 })?.windowID, 2)
        XCTAssertEqual(plan.placements.first(where: { $0.slotIndex == 1 })?.windowID, 1)
    }

    func testTitleContainsDisambiguatesSameBundleID() {
        // Two Chrome windows, same bundle ID, different profiles by title.
        let work = MockWindow(id: 1, bundleID: "com.google.Chrome", title: "Inbox - Work - Google Chrome")
        let personal = MockWindow(id: 2, bundleID: "com.google.Chrome", title: "YouTube - Personal - Google Chrome")
        let plan = LayoutEngine.plan(
            windows: [work, personal],
            visibleFrame: vf,
            layout: .halves,
            assignments: [
                WorkspaceSlotAssignment(slotIndex: 0, bundleID: "com.google.Chrome", titleContains: "Personal"),
                WorkspaceSlotAssignment(slotIndex: 1, bundleID: "com.google.Chrome", titleContains: "Work"),
            ]
        )
        XCTAssertEqual(plan.placements.first(where: { $0.slotIndex == 0 })?.windowID, 2)
        XCTAssertEqual(plan.placements.first(where: { $0.slotIndex == 1 })?.windowID, 1)
    }

    func testUnmatchedTitleHintFallsThroughToFillPass() {
        // No window's title matches the hint — the assignment simply misses,
        // and the window still lands somewhere via the ordinary fill pass
        // rather than being dropped.
        let only = MockWindow(id: 1, bundleID: "com.google.Chrome", title: "Something Else")
        let plan = LayoutEngine.plan(
            windows: [only],
            visibleFrame: vf,
            layout: .halves,
            assignments: [
                WorkspaceSlotAssignment(slotIndex: 0, bundleID: "com.google.Chrome", titleContains: "Work"),
            ]
        )
        XCTAssertEqual(plan.placements.count, 1)
        XCTAssertEqual(plan.placements.first?.windowID, 1)
    }

    func testOutOfRangeSlotIndexIsIgnored() {
        let w = MockWindow(id: 1, bundleID: "com.example.app")
        let plan = LayoutEngine.plan(
            windows: [w],
            visibleFrame: vf,
            layout: .halves,
            assignments: [WorkspaceSlotAssignment(slotIndex: 99, bundleID: "com.example.app")]
        )
        // Falls through to the ordinary fill pass instead of being dropped.
        XCTAssertEqual(plan.placements.count, 1)
        XCTAssertEqual(plan.placements.first?.slotIndex, 0)
    }

    func testEmptyAssignmentsBehavesLikePreExistingEngine() {
        let ws = [
            MockWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 500, height: 1000)),
            MockWindow(id: 2, frame: CGRect(x: 500, y: 0, width: 500, height: 1000)),
        ]
        let plan = LayoutEngine.plan(windows: ws, visibleFrame: vf, layout: .halves, assignments: [])
        XCTAssertEqual(plan.placements, [
            Placement(windowID: 1, targetFrame: CGRect(x: 0, y: 0, width: 500, height: 1000), slotIndex: 0),
            Placement(windowID: 2, targetFrame: CGRect(x: 500, y: 0, width: 500, height: 1000), slotIndex: 1),
        ])
    }
}
