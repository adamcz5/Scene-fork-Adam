import XCTest
@testable import SceneCore

final class AppSwitcherLogicTests: XCTestCase {

    // MARK: - candidates

    func testCandidatesOrderedByMRUNotConfigOrder() {
        let config = AppSwitcherConfig(enabled: true, bundleIDs: ["a", "b", "c"])
        // Config lists a, b, c but "c" was activated most recently.
        let mru = ["c", "a", "b"]
        let running: Set<String> = ["a", "b", "c"]
        XCTAssertEqual(AppSwitcherLogic.candidates(config: config, mruOrder: mru, runningBundleIDs: running), ["c", "a", "b"])
    }

    func testCandidatesFiltersOutNotRunningAndNotAllowed() {
        let config = AppSwitcherConfig(enabled: true, bundleIDs: ["a", "b", "c"])
        let mru = ["z", "c", "a", "b"] // "z" isn't in the allow-list at all
        let running: Set<String> = ["c", "a"] // "b" isn't running
        XCTAssertEqual(AppSwitcherLogic.candidates(config: config, mruOrder: mru, runningBundleIDs: running), ["c", "a"])
    }

    func testCandidatesAppendsRunningAppsMissingFromMRUOrder() {
        // "b" is allow-listed and running but was never activated this
        // session (not yet in the MRU list) — it should still show up,
        // appended after the MRU-ordered ones, not silently disappear.
        let config = AppSwitcherConfig(enabled: true, bundleIDs: ["a", "b", "c"])
        let mru = ["c", "a"]
        let running: Set<String> = ["a", "b", "c"]
        XCTAssertEqual(AppSwitcherLogic.candidates(config: config, mruOrder: mru, runningBundleIDs: running), ["c", "a", "b"])
    }

    func testCandidatesEmptyWhenDisabled() {
        let config = AppSwitcherConfig(enabled: false, bundleIDs: ["a", "b"])
        XCTAssertEqual(AppSwitcherLogic.candidates(config: config, mruOrder: ["a", "b"], runningBundleIDs: ["a", "b"]), [])
    }

    func testCandidatesEmptyWhenNoneRunning() {
        let config = AppSwitcherConfig(enabled: true, bundleIDs: ["a", "b"])
        XCTAssertEqual(AppSwitcherLogic.candidates(config: config, mruOrder: ["a", "b"], runningBundleIDs: ["z"]), [])
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
