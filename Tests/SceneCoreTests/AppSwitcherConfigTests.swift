import XCTest
@testable import SceneCore

final class AppSwitcherConfigTests: XCTestCase {
    func testBundleIDsConvenienceInitCreatesPlainEntries() {
        let config = AppSwitcherConfig(enabled: true, bundleIDs: ["a", "b"])
        XCTAssertEqual(config.entries.map(\.bundleID), ["a", "b"])
        XCTAssertTrue(config.entries.allSatisfy { $0.titleContains == nil && $0.label == nil && $0.colorHex == nil })
        XCTAssertEqual(config.bundleIDs, ["a", "b"])
    }

    func testEntriesRoundTrip() throws {
        let entry = AppSwitcherEntry(bundleID: "com.google.Chrome", titleContains: "Work", label: "Work", colorHex: "#4C8BF5")
        let original = AppSwitcherConfig(enabled: true, entries: [entry])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSwitcherConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testDecodesLegacyFlatBundleIDsSchema() throws {
        // Pre-V0.10 persisted shape: no "entries" key, just "bundleIDs".
        let json = #"{"enabled":true,"bundleIDs":["com.google.Chrome","com.apple.Notes"]}"#
        let decoded = try JSONDecoder().decode(AppSwitcherConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.bundleIDs, ["com.google.Chrome", "com.apple.Notes"])
        XCTAssertTrue(decoded.entries.allSatisfy { $0.titleContains == nil })
    }

    func testDecodesMissingBundleIDsAsEmpty() throws {
        // Fresh V0.9 install shape with an absent bundleIDs key entirely.
        let json = #"{"enabled":false}"#
        let decoded = try JSONDecoder().decode(AppSwitcherConfig.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.entries.isEmpty)
    }

    func testEncodedFormUsesEntriesNotLegacyBundleIDs() throws {
        let config = AppSwitcherConfig(enabled: true, bundleIDs: ["a"])
        let data = try JSONEncoder().encode(config)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"entries\""))
        XCTAssertFalse(json.contains("\"bundleIDs\""), "should always write the current entries-based schema, never the legacy flat one")
    }
}
