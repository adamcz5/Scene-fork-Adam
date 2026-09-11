import XCTest
@testable import SceneCore

final class AppSwitcherLogicTests: XCTestCase {

    // MARK: - candidates

    func testCandidatesOrderedByMRUNotConfigOrder() {
        let config = AppSwitcherConfig(enabled: true, bundleIDs: ["a", "b", "c"])
        // Config lists a, b, c but "c" was activated most recently.
        let mru = ["c", "a", "b"]
        let running: Set<String> = ["a", "b", "c"]
        let result = AppSwitcherLogic.candidates(config: config, mruOrder: mru, runningBundleIDs: running)
        XCTAssertEqual(result.map(\.bundleID), ["c", "a", "b"])
    }

    func testCandidatesFiltersOutNotRunningAndNotAllowed() {
        let config = AppSwitcherConfig(enabled: true, bundleIDs: ["a", "b", "c"])
        let mru = ["z", "c", "a", "b"] // "z" isn't in the allow-list at all
        let running: Set<String> = ["c", "a"] // "b" isn't running
        let result = AppSwitcherLogic.candidates(config: config, mruOrder: mru, runningBundleIDs: running)
        XCTAssertEqual(result.map(\.bundleID), ["c", "a"])
    }

    func testCandidatesAppendsRunningAppsMissingFromMRUOrder() {
        // "b" is allow-listed and running but was never activated this
        // session (not yet in the MRU list) — it should still show up,
        // appended after the MRU-ordered ones, not silently disappear.
        let config = AppSwitcherConfig(enabled: true, bundleIDs: ["a", "b", "c"])
        let mru = ["c", "a"]
        let running: Set<String> = ["a", "b", "c"]
        let result = AppSwitcherLogic.candidates(config: config, mruOrder: mru, runningBundleIDs: running)
        XCTAssertEqual(result.map(\.bundleID), ["c", "a", "b"])
    }

    func testCandidatesEmptyWhenDisabled() {
        let config = AppSwitcherConfig(enabled: false, bundleIDs: ["a", "b"])
        XCTAssertEqual(AppSwitcherLogic.candidates(config: config, mruOrder: ["a", "b"], runningBundleIDs: ["a", "b"]), [])
    }

    func testCandidatesEmptyWhenNoneRunning() {
        let config = AppSwitcherConfig(enabled: true, bundleIDs: ["a", "b"])
        XCTAssertEqual(AppSwitcherLogic.candidates(config: config, mruOrder: ["a", "b"], runningBundleIDs: ["z"]), [])
    }

    // MARK: - candidates: titleContains-filtered entries (Chrome profile split)

    func testTitleFilteredEntryMatchesOnlyWhenAWindowTitleContainsIt() {
        let personal = AppSwitcherEntry(bundleID: "com.google.Chrome", titleContains: "Personal", label: "Personal")
        let work = AppSwitcherEntry(bundleID: "com.google.Chrome", titleContains: "Work", label: "Work")
        let config = AppSwitcherConfig(enabled: true, entries: [personal, work])
        let running: Set<String> = ["com.google.Chrome"]

        let result = AppSwitcherLogic.candidates(
            config: config, mruOrder: [], runningBundleIDs: running,
            windowTitles: { _ in ["Inbox – Work – Google Chrome"] }
        )
        XCTAssertEqual(result.map(\.id), [work.id], "only the entry whose filter matches an open window's title should show")
    }

    func testTitleFilteredEntryHiddenWhenNoWindowTitleMatches() {
        let entry = AppSwitcherEntry(bundleID: "com.google.Chrome", titleContains: "Work")
        let config = AppSwitcherConfig(enabled: true, entries: [entry])
        let result = AppSwitcherLogic.candidates(
            config: config, mruOrder: [], runningBundleIDs: ["com.google.Chrome"],
            windowTitles: { _ in ["Personal – Google Chrome"] }
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testTitleFilteredEntryHiddenWithoutWindowTitleProvider() {
        // Default `windowTitles` closure returns [] — simulates "Accessibility
        // not granted, can't read titles" — so a title-filtered entry must be
        // dropped rather than guessed as present.
        let entry = AppSwitcherEntry(bundleID: "com.google.Chrome", titleContains: "Work")
        let config = AppSwitcherConfig(enabled: true, entries: [entry])
        let result = AppSwitcherLogic.candidates(config: config, mruOrder: [], runningBundleIDs: ["com.google.Chrome"])
        XCTAssertTrue(result.isEmpty)
    }

    func testUnfilteredEntryIgnoresWindowTitles() {
        let entry = AppSwitcherEntry(bundleID: "com.apple.Notes")
        let config = AppSwitcherConfig(enabled: true, entries: [entry])
        let result = AppSwitcherLogic.candidates(config: config, mruOrder: [], runningBundleIDs: ["com.apple.Notes"])
        XCTAssertEqual(result.map(\.id), [entry.id])
    }

    func testSameBundleEntriesKeepConfiguredOrderAsStableTiebreak() {
        // A plain bundle ID in `mruOrder` (as opposed to an entry's own
        // `mruKey`) matches neither profile-split entry's key — this is what
        // `AppSwitcherController.recordActivation` produces when it can't
        // resolve which profile is actually frontmost (AX unavailable, or no
        // window title matched either filter), and ties should resolve by
        // configured (entries array) order rather than guessing.
        let personal = AppSwitcherEntry(bundleID: "com.google.Chrome", titleContains: "Personal")
        let work = AppSwitcherEntry(bundleID: "com.google.Chrome", titleContains: "Work")
        let config = AppSwitcherConfig(enabled: true, entries: [personal, work])
        let result = AppSwitcherLogic.candidates(
            config: config, mruOrder: ["com.google.Chrome"], runningBundleIDs: ["com.google.Chrome"],
            windowTitles: { _ in ["Personal", "Work"] }
        )
        XCTAssertEqual(result.map(\.id), [personal.id, work.id])
    }

    func testProfileSplitEntriesRankIndependentlyByMRUKey() {
        // Once the caller HAS resolved which specific profile was activated
        // (via each entry's own `mruKey`, not just the shared bundle ID),
        // only that entry should move — its sibling profile must not tag
        // along just because they share a bundle ID.
        let personal = AppSwitcherEntry(bundleID: "com.google.Chrome", titleContains: "Personal")
        let work = AppSwitcherEntry(bundleID: "com.google.Chrome", titleContains: "Work")
        let other = AppSwitcherEntry(bundleID: "com.apple.Notes")
        let config = AppSwitcherConfig(enabled: true, entries: [personal, work, other])
        let mru = [work.mruKey, "com.apple.Notes"]
        let result = AppSwitcherLogic.candidates(
            config: config, mruOrder: mru, runningBundleIDs: ["com.google.Chrome", "com.apple.Notes"],
            windowTitles: { _ in ["Personal", "Work"] }
        )
        XCTAssertEqual(result.map(\.id), [work.id, other.id, personal.id])
    }

    // MARK: - startIndex

    func testStartIndexJumpsPastFrontmostApp() {
        let candidates = ["a", "b", "c"].map { AppSwitcherEntry(bundleID: $0) }
        XCTAssertEqual(AppSwitcherLogic.startIndex(candidates: candidates, frontmostBundleID: "a"), 1)
        XCTAssertEqual(AppSwitcherLogic.startIndex(candidates: candidates, frontmostBundleID: "c"), 0, "wraps past the last entry")
    }

    func testStartIndexZeroWhenFrontmostNotInRing() {
        let candidates = ["a", "b", "c"].map { AppSwitcherEntry(bundleID: $0) }
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
