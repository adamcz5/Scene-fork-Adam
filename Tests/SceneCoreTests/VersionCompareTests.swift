import XCTest
@testable import SceneCore

final class VersionCompareTests: XCTestCase {
    // MARK: - Positive cases (tag IS newer)

    func testPatchBump() {
        XCTAssertTrue(isVersionTag("0.4.3", newerThan: "0.4.2"))
    }

    func testMinorBump() {
        XCTAssertTrue(isVersionTag("0.5.0", newerThan: "0.4.9"))
    }

    func testMajorBump() {
        XCTAssertTrue(isVersionTag("1.0.0", newerThan: "0.99.99"))
    }

    func testTagWithVPrefix() {
        XCTAssertTrue(isVersionTag("v0.4.3", newerThan: "0.4.2"))
    }

    func testBundleWithVPrefix() {
        XCTAssertTrue(isVersionTag("0.4.3", newerThan: "v0.4.2"))
    }

    func testTagHasMoreComponents() {
        // `"0.4.2.1"` vs `"0.4.2"` — the 4th component makes the tag newer.
        XCTAssertTrue(isVersionTag("0.4.2.1", newerThan: "0.4.2"))
    }

    // MARK: - Negative cases (tag NOT newer)

    func testSameVersion() {
        XCTAssertFalse(isVersionTag("0.4.2", newerThan: "0.4.2"))
    }

    func testSameVersionWithMixedPrefix() {
        XCTAssertFalse(isVersionTag("v0.4.2", newerThan: "0.4.2"))
    }

    func testOlderPatch() {
        XCTAssertFalse(isVersionTag("0.4.1", newerThan: "0.4.2"))
    }

    func testOlderMinor() {
        XCTAssertFalse(isVersionTag("0.3.99", newerThan: "0.4.0"))
    }

    func testOlderMajor() {
        XCTAssertFalse(isVersionTag("0.99.0", newerThan: "1.0.0"))
    }

    func testShorterBundleTreatedAsZeroPadded() {
        // `"1.2"` is equivalent to `"1.2.0"`; neither is newer than the other.
        XCTAssertFalse(isVersionTag("1.2", newerThan: "1.2.0"))
        XCTAssertFalse(isVersionTag("1.2.0", newerThan: "1.2"))
    }

    func testTagHasMoreTrailingZeros() {
        // Extra trailing zeros are semantically equal.
        XCTAssertFalse(isVersionTag("0.4.2.0", newerThan: "0.4.2"))
        XCTAssertFalse(isVersionTag("0.4.2", newerThan: "0.4.2.0"))
    }

    // MARK: - Fail-safe on malformed input

    func testUnparseableTagReturnsFalse() {
        // Pre-release suffix like `"0.4.3-beta"` parses as `[0, 4]` (the
        // `"3-beta"` component drops out). That collapses to `0.4.0` which
        // is NOT newer than `0.4.2` — desired: no spurious nudge.
        XCTAssertFalse(isVersionTag("0.4.3-beta", newerThan: "0.4.2"))
    }

    func testEmptyTagReturnsFalse() {
        XCTAssertFalse(isVersionTag("", newerThan: "0.4.2"))
    }

    func testEmptyBundleReturnsFalse() {
        XCTAssertFalse(isVersionTag("0.4.3", newerThan: ""))
    }

    func testBothEmptyReturnsFalse() {
        XCTAssertFalse(isVersionTag("", newerThan: ""))
    }

    func testGarbageReturnsFalse() {
        XCTAssertFalse(isVersionTag("not.a.version", newerThan: "0.4.2"))
        XCTAssertFalse(isVersionTag("0.4.2", newerThan: "garbage"))
    }

    func testJustVPrefixReturnsFalse() {
        XCTAssertFalse(isVersionTag("v", newerThan: "0.4.2"))
    }
}

/// `indexOfHighestVersion` replaces GitHub's `releases/latest`, which sorts by
/// the tag's *commit* date rather than by version number.
final class HighestVersionSelectionTests: XCTestCase {
    func testEmptyListReturnsNil() {
        XCTAssertNil(indexOfHighestVersion(tags: []))
    }

    func testSingleTagReturnsItsIndex() {
        XCTAssertEqual(indexOfHighestVersion(tags: ["v0.7.3"]), 0)
    }

    func testPicksHighestFromGitHubListingOrder() {
        // GitHub returns newest-created first, which is usually also newest by
        // version — the happy path must keep working.
        let tags = ["v0.7.3", "v0.7.2", "v0.7.1", "v0.6.1", "v0.1.0"]
        XCTAssertEqual(indexOfHighestVersion(tags: tags), 0)
    }

    func testPicksHighestWhenCreatedAtOrderDisagreesWithVersionOrder() {
        // The reported bug: v0.7.4 was cut from an older commit, so GitHub
        // sorts it *below* v0.7.3 and `releases/latest` returns v0.7.3. A user
        // on v0.5.0 would be offered v0.7.3, install it, then be offered
        // v0.7.4 on relaunch — one version at a time.
        let tags = ["v0.7.3", "v0.7.4", "v0.7.2"]
        XCTAssertEqual(indexOfHighestVersion(tags: tags), 1)
    }

    func testDoubleDigitComponentBeatsSingleDigit() {
        // Pure string sorting puts "v0.9.0" above "v0.10.0". Numeric must not.
        XCTAssertEqual(indexOfHighestVersion(tags: ["v0.9.0", "v0.10.0"]), 1)
        XCTAssertEqual(indexOfHighestVersion(tags: ["v0.10.0", "v0.9.0"]), 0)
    }

    func testMajorBumpWins() {
        XCTAssertEqual(indexOfHighestVersion(tags: ["v0.99.99", "v1.0.0"]), 1)
    }

    func testUnparseableTagsAreSkipped() {
        XCTAssertEqual(indexOfHighestVersion(tags: ["nightly", "v0.7.3"]), 1)
        XCTAssertEqual(indexOfHighestVersion(tags: ["v0.7.3", "nightly"]), 0)
    }

    func testAllUnparseableReturnsNil() {
        XCTAssertNil(indexOfHighestVersion(tags: ["nightly", "", "v", "garbage"]))
    }

    func testTieResolvesToEarliestIndex() {
        // Earliest index is newest by created_at in GitHub's listing order.
        XCTAssertEqual(indexOfHighestVersion(tags: ["v0.7.3", "v0.7.3"]), 0)
    }

    func testZeroPaddedEquivalentsTie() {
        // "0.7" == "0.7.0" — neither is newer, so the earliest index holds.
        XCTAssertEqual(indexOfHighestVersion(tags: ["v0.7", "v0.7.0"]), 0)
    }

    func testRealSceneReleaseHistoryPicksNewest() {
        let tags = [
            "v0.7.3", "v0.7.2", "v0.7.1", "v0.7.0", "v0.6.1", "v0.6.0",
            "v0.5.7", "v0.5.6", "v0.5.5", "v0.5.4", "v0.5.3", "v0.5.2",
            "v0.5.1", "v0.5.0", "v0.4.3", "v0.4.2", "v0.4.1", "v0.4.0", "v0.1.0",
        ]
        XCTAssertEqual(indexOfHighestVersion(tags: tags), 0)
        // And a v0.1.0 user jumps straight to it, not through 18 hops.
        XCTAssertTrue(isVersionTag(tags[0], newerThan: "0.1.0"))
    }
}
