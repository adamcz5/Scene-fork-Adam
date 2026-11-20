import XCTest
@testable import SceneCore

final class SpotlightConfigTests: XCTestCase {
    func testDefaultIsDisabledActiveWindow() {
        XCTAssertFalse(SpotlightConfig.default.enabled)
        XCTAssertEqual(SpotlightConfig.default.scope, .activeWindow)
        XCTAssertEqual(SpotlightConfig.default.idleDelaySeconds, SpotlightConfig.defaultIdleDelaySeconds)
    }

    func testCodableRoundTrip() throws {
        let original = SpotlightConfig(enabled: true, scope: .activeApp, idleDelaySeconds: 5)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SpotlightConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMissingKeysDecodeToDefaults() throws {
        let data = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SpotlightConfig.self, from: data)
        XCTAssertEqual(decoded, SpotlightConfig.default)
    }

    func testPartialJSONFillsOnlyMissingFields() throws {
        let data = #"{"enabled":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SpotlightConfig.self, from: data)
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.scope, .activeWindow)
        XCTAssertEqual(decoded.idleDelaySeconds, SpotlightConfig.defaultIdleDelaySeconds)
    }
}
