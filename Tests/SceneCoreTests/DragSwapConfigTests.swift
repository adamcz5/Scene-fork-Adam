import XCTest
@testable import SceneCore

final class DragSwapConfigTests: XCTestCase {
    func testDefaults() {
        let d = DragSwapConfig.default
        XCTAssertTrue(d.enabled)
        XCTAssertEqual(d.distanceThresholdPt, 30)
    }

    func testClampsThresholdBelowMinimum() {
        let c = DragSwapConfig(enabled: true, distanceThresholdPt: 5)
        XCTAssertEqual(c.distanceThresholdPt, 10)
    }

    func testClampsThresholdAboveMaximum() {
        let c = DragSwapConfig(enabled: true, distanceThresholdPt: 500)
        XCTAssertEqual(c.distanceThresholdPt, 100)
    }

    func testCodableRoundTrip() throws {
        let original = DragSwapConfig(enabled: false, distanceThresholdPt: 45)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DragSwapConfig.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testDecodeClampsOutOfRangeValue() throws {
        let json = #"{"enabled":true,"distanceThresholdPt":200}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DragSwapConfig.self, from: json)
        XCTAssertEqual(decoded.distanceThresholdPt, 100)
    }

    // MARK: - autoDisableAfterSeconds (timed stickiness)

    func testAutoDisableAfterSecondsDefaultsToNil() {
        XCTAssertNil(DragSwapConfig.default.autoDisableAfterSeconds)
    }

    func testClampsAutoDisableSecondsBelowMinimum() {
        let c = DragSwapConfig(enabled: true, distanceThresholdPt: 30, autoDisableAfterSeconds: 0.5)
        XCTAssertEqual(c.autoDisableAfterSeconds, DragSwapConfig.minAutoDisableSeconds)
    }

    func testClampsAutoDisableSecondsAboveMaximum() {
        let c = DragSwapConfig(enabled: true, distanceThresholdPt: 30, autoDisableAfterSeconds: 999)
        XCTAssertEqual(c.autoDisableAfterSeconds, DragSwapConfig.maxAutoDisableSeconds)
    }

    func testDecodingWithoutAutoDisableKeyDefaultsToNil() throws {
        // Pre-V0.9 persisted files never wrote this key — must decode as nil,
        // not throw, so upgrading users keep their existing config.
        let json = #"{"enabled":true,"distanceThresholdPt":30}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DragSwapConfig.self, from: json)
        XCTAssertNil(decoded.autoDisableAfterSeconds)
    }

    func testCodableRoundTripPreservesAutoDisableSeconds() throws {
        let original = DragSwapConfig(enabled: true, distanceThresholdPt: 30, autoDisableAfterSeconds: 5)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DragSwapConfig.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testWithEnabledPreservesOtherFields() {
        let original = DragSwapConfig(enabled: true, distanceThresholdPt: 42, autoDisableAfterSeconds: 7)
        let disabled = original.withEnabled(false)
        XCTAssertFalse(disabled.enabled)
        XCTAssertEqual(disabled.distanceThresholdPt, 42)
        XCTAssertEqual(disabled.autoDisableAfterSeconds, 7)
    }

    // MARK: - stickyModeOption / applying(_:to:)

    func testStickyModeOptionReflectsConfig() {
        XCTAssertEqual(DragSwapConfig(enabled: false, distanceThresholdPt: 30).stickyModeOption, .off)
        XCTAssertEqual(DragSwapConfig(enabled: true, distanceThresholdPt: 30).stickyModeOption, .always)
        XCTAssertEqual(
            DragSwapConfig(enabled: true, distanceThresholdPt: 30, autoDisableAfterSeconds: 5).stickyModeOption,
            .timed
        )
    }

    func testApplyingTimedPreservesPreviousDurationWhenReenabled() throws {
        let store = try SettingsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json"))
        let timed = DragSwapConfig(enabled: true, distanceThresholdPt: 30, autoDisableAfterSeconds: 12)
        timed.applying(.off, to: store)
        XCTAssertEqual(store.dragSwap.autoDisableAfterSeconds, 12, "turning off shouldn't forget the configured duration")
        store.dragSwap.applying(.timed, to: store)
        XCTAssertEqual(store.dragSwap.autoDisableAfterSeconds, 12)
        XCTAssertTrue(store.dragSwap.enabled)
    }
}
