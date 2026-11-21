import XCTest
@testable import SceneCore

final class SpotlightConfigTests: XCTestCase {
    func testDefaultIsDisabledSingleWithStandardLook() {
        let d = SpotlightConfig.default
        XCTAssertFalse(d.enabled)
        XCTAssertEqual(d.exclusionMode, .single)
        XCTAssertEqual(d.idleDelaySeconds, SpotlightConfig.defaultIdleDelaySeconds)
        XCTAssertEqual(d.darkness, SpotlightConfig.defaultDarkness)
        XCTAssertEqual(d.blurPreset, .heavy)
        XCTAssertEqual(d.speed, SpotlightConfig.defaultSpeed)
        XCTAssertNil(d.hotkey)
        XCTAssertFalse(d.dimBrowserChrome)
        XCTAssertEqual(d.browserChromeMode, .automatic)
        XCTAssertEqual(d.browserChromeHeight, SpotlightConfig.defaultChromeHeight)
        XCTAssertEqual(d.browserChromeDarkness, SpotlightConfig.defaultChromeDarkness)
        XCTAssertEqual(d.browserChromeBlurRadius, SpotlightConfig.defaultChromeBlurRadius)
        XCTAssertNil(d.browserChromeHotkey)
        XCTAssertEqual(d.exceptionBundleIDs, [])
        XCTAssertFalse(d.browserChromeLight)
        XCTAssertEqual(d.effectiveChromeDarkness, d.browserChromeDarkness)
    }

    func testCodableRoundTrip() throws {
        let original = SpotlightConfig(
            enabled: true,
            exclusionMode: .perMonitor,
            idleDelaySeconds: 5,
            darkness: 0.7,
            blurPreset: .light,
            speed: 2,
            hotkey: HotkeyBinding(keyCode: 2, modifiers: [.command, .option]),
            dimBrowserChrome: true,
            browserChromeMode: .fixedHeight,
            browserChromeHeight: 120,
            browserChromeDarkness: 0.8,
            browserChromeBlurRadius: 8,
            browserChromeHotkey: HotkeyBinding(keyCode: 3, modifiers: [.command, .shift]),
            exceptionBundleIDs: ["com.anthropic.claudefordesktop"],
            browserChromeLight: true,
            browserChromeLightDarkness: 0.3,
            browserChromeLightBlurRadius: 2
        )
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
        XCTAssertEqual(decoded.exclusionMode, .single)
        XCTAssertEqual(decoded.idleDelaySeconds, SpotlightConfig.defaultIdleDelaySeconds)
        XCTAssertEqual(decoded.darkness, SpotlightConfig.defaultDarkness)
        XCTAssertEqual(decoded.blurPreset, .heavy)
    }

    /// A file written by an older build, which still had the (since removed)
    /// `scope` key and none of the look/hotkey fields.
    func testLegacyJSONWithRemovedScopeKeyStillDecodes() throws {
        let data = #"{"enabled":true,"scope":"activeApp","idleDelaySeconds":4,"exclusionMode":"perMonitor"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SpotlightConfig.self, from: data)
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.idleDelaySeconds, 4)
        XCTAssertEqual(decoded.exclusionMode, .perMonitor)
        XCTAssertEqual(decoded.darkness, SpotlightConfig.defaultDarkness)
    }
}
