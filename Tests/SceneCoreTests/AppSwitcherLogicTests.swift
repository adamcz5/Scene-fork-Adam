import XCTest
@testable import SceneCore

final class AppSwitcherLogicTests: XCTestCase {

    // MARK: - candidates

    func testCandidatesFiltersToConfiguredOrderNotRunningOrder() {
        let config = AppSwitcherConfig(enabled: true, bundleIDs: ["a", "b", "c"])
        // Running set is unordered by nature; "c" and "a" running, "b" not.
        let running: Set<String> = ["c", "a"]
        XCTAssertEqual(AppSwitcherLogic.candidates(config: config, runningBundleIDs: running), ["a", "c"])
    }

    func testCandidatesEmptyWhenDisabled() {
        let config = AppSwitcherConfig(enabled: false, bundleIDs: ["a", "b"])
        XCTAssertEqual(AppSwitcherLogic.candidates(config: config, runningBundleIDs: ["a", "b"]), [])
    }

    func testCandidatesEmptyWhenNoneRunning() {
        let config = AppSwitcherConfig(enabled: true, bundleIDs: ["a", "b"])
        XCTAssertEqual(AppSwitcherLogic.candidates(config: config, runningBundleIDs: ["z"]), [])
    }

    // MARK: - startIndex

    func testStartIndexJumpsPastFrontmostApp() {
        let candidates = ["a", "b", "c"]
        XCTAssertEqual(AppSwitcherLogic.startIndex(candidates: candidates, frontmostBundleID: "a"), 1)
        XCTAssertEqual(AppSwitcherLogic.startIndex(candidates: candidates, frontmostBundleID: "c"), 0, "wraps past the last entry")
    }

    func testStartIndexZeroWhenFrontmostNotInRing() {
        let candidates = ["a", "b", "c"]
        XCTAssertEqual(AppSwitcherLogic.startIndex(candidates: candidates, frontmostBundleID: "z"), 0)
        XCTAssertEqual(AppSwitcherLogic.startIndex(candidates: candidates, frontmostBundleID: nil), 0)
    }

    func testStartIndexZeroForEmptyRing() {
        XCTAssertEqual(AppSwitcherLogic.startIndex(candidates: [], frontmostBundleID: "a"), 0)
    }

    // MARK: - advance

    func testAdvanceForwardWraps() {
        XCTAssertEqual(AppSwitcherLogic.advance(index: 0, count: 3, reverse: false), 1)
        XCTAssertEqual(AppSwitcherLogic.advance(index: 2, count: 3, reverse: false), 0)
    }

    func testAdvanceReverseWraps() {
        XCTAssertEqual(AppSwitcherLogic.advance(index: 0, count: 3, reverse: true), 2)
        XCTAssertEqual(AppSwitcherLogic.advance(index: 2, count: 3, reverse: true), 1)
    }

    func testAdvanceEmptyRingReturnsZero() {
        XCTAssertEqual(AppSwitcherLogic.advance(index: 0, count: 0, reverse: false), 0)
        XCTAssertEqual(AppSwitcherLogic.advance(index: 0, count: 0, reverse: true), 0)
    }

    func testAdvanceSingleEntryRingStaysPut() {
        XCTAssertEqual(AppSwitcherLogic.advance(index: 0, count: 1, reverse: false), 0)
        XCTAssertEqual(AppSwitcherLogic.advance(index: 0, count: 1, reverse: true), 0)
    }
}
