import XCTest
@testable import SceneCore

final class RectMergingTests: XCTestCase {
    func testDisjointRectsPassThroughUnchanged() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        let b = CGRect(x: 100, y: 100, width: 10, height: 10)
        let result = Set(RectMerging.mergingOverlapping([a, b]).map { $0 })
        XCTAssertEqual(result, Set([a, b]))
    }

    func testOverlappingRectsMergeIntoUnion() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        let b = CGRect(x: 5, y: 5, width: 10, height: 10)
        let result = RectMerging.mergingOverlapping([a, b])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first, a.union(b))
    }

    func testChainOfOverlapsMergesTransitively() {
        // a overlaps b, b overlaps c, a does NOT overlap c directly —
        // all three must still end up in one merged rect.
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        let b = CGRect(x: 8, y: 0, width: 10, height: 10)
        let c = CGRect(x: 16, y: 0, width: 10, height: 10)
        let result = RectMerging.mergingOverlapping([a, b, c])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first, a.union(b).union(c))
    }

    func testEmptyRectsAreDropped() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        let empty = CGRect.zero
        let result = RectMerging.mergingOverlapping([a, empty])
        XCTAssertEqual(result, [a])
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(RectMerging.mergingOverlapping([]).isEmpty)
    }

    func testNoInputMutationForSingleRect() {
        let a = CGRect(x: 1, y: 2, width: 3, height: 4)
        XCTAssertEqual(RectMerging.mergingOverlapping([a]), [a])
    }
}
