import XCTest
@testable import Core

/// Tests for the tool-call timeout setting and its derived values. This is
/// the deterministic, process-free part of the feature: the setting's
/// defaults, the enabled/disabled `duration` derivation, the display text, and
/// the UserDefaults round-trip. The abort itself runs against the live agent
/// process (integration only), so it is not covered here.
final class ToolTimeoutSettingsTests: XCTestCase {

    private static let secondsKey = "toolTimeout.seconds"
    private static let enabledKey = "toolTimeout.isEnabled"

    override func setUp() {
        super.setUp()
        // Save the current defaults so the test can restore them (UserDefaults
        // is process-wide; these tests must not leak their values to others).
        persistedSeconds = UserDefaults.standard.object(forKey: Self.secondsKey)
        persistedEnabled = UserDefaults.standard.object(forKey: Self.enabledKey)
        // Remove any saved value so `load()` falls back to the default.
        UserDefaults.standard.removeObject(forKey: Self.secondsKey)
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
    }

    override func tearDown() {
        // Restore whatever was there before the test.
        if let s = persistedSeconds {
            UserDefaults.standard.set(s, forKey: Self.secondsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.secondsKey)
        }
        if let e = persistedEnabled {
            UserDefaults.standard.set(e, forKey: Self.enabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.enabledKey)
        }
        super.tearDown()
    }

    private var persistedSeconds: Any?
    private var persistedEnabled: Any?

    func testDefaultsAreTenMinutesAndEnabled() {
        XCTAssertEqual(ToolTimeoutSettings.defaultSeconds, 600,
            "the default limit is 10 minutes")
        let settings = ToolTimeoutSettings.defaults
        XCTAssertEqual(settings.seconds, 600)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.duration, .seconds(600),
            "the default must yield an enforced duration")
    }

    func testLoadFallsBackToDefaultsWhenUnset() {
        let settings = ToolTimeoutSettings.load()
        XCTAssertEqual(settings, ToolTimeoutSettings.defaults,
            "with no stored values, load() returns the default")
    }

    func testDurationIsNilWhenDisabled() {
        let settings = ToolTimeoutSettings(seconds: 600, isEnabled: false)
        XCTAssertNil(settings.duration, "a disabled timeout must not schedule an abort")
        XCTAssertEqual(settings.displayText, "no limit")
    }

    func testDurationIsNilForNonPositiveSeconds() {
        XCTAssertNil(ToolTimeoutSettings(seconds: 0, isEnabled: true).duration)
        XCTAssertNil(ToolTimeoutSettings(seconds: -5, isEnabled: true).duration)
    }

    func testDisplayTextAdaptsToGranularity() {
        XCTAssertEqual(ToolTimeoutSettings(seconds: 600).displayText, "10 minutes")
        XCTAssertEqual(ToolTimeoutSettings(seconds: 60).displayText, "1 minute")
        XCTAssertEqual(ToolTimeoutSettings(seconds: 90).displayText, "90 seconds")
    }

    func testSaveLoadRoundTrips() {
        let saved = ToolTimeoutSettings(seconds: 300, isEnabled: false)
        saved.save()
        let loaded = ToolTimeoutSettings.load()
        XCTAssertEqual(loaded, saved, "save() then load() must round-trip exactly")
        XCTAssertNil(loaded.duration, "an explicitly disabled limit stays disabled")
    }
}
