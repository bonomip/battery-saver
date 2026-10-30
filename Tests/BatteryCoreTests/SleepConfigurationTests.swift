import XCTest
@testable import BatteryCore

final class SleepConfigurationTests: XCTestCase {
    private let oldSettings = #"{"enabled":true,"lower":75,"upper":80,"heatPause":38,"heatResume":35}"#

    func testOldSettingsDefaultToKeepingAwake() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data(oldSettings.utf8))
        XCTAssertTrue(settings.keepAwakeUntilLimit)
        XCTAssertTrue(Settings().keepAwakeUntilLimit)
        try settings.validate()
    }

    func testExplicitFalseRoundTripsAndCanonicalEncodingIncludesFlag() throws {
        let settings = Settings(keepAwakeUntilLimit: false)
        let encoded = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: encoded), settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["keepAwakeUntilLimit"] as? Bool, false)
    }

    func testMalformedFlagAndMissingRequiredSettingsFail() {
        let malformed = oldSettings.dropLast() + #", "keepAwakeUntilLimit":"yes"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Settings.self, from: Data(malformed.utf8)))
        let nullFlag = oldSettings.dropLast() + #", "keepAwakeUntilLimit":null}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Settings.self, from: Data(nullFlag.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Settings.self, from: Data(#"{"enabled":true}"#.utf8)))
    }

    func testOldStatusDefaultsSleepFieldsAndRetainsRequiredRunning() throws {
        let json = #"{"date":0,"state":"Paused","settings":SETTINGS,"backend":"test","calibrationActive":false,"running":true}"#.replacingOccurrences(of: "SETTINGS", with: oldSettings)
        let status = try JSONDecoder().decode(HelperStatus.self, from: Data(json.utf8))
        XCTAssertFalse(status.sleepControlAvailable)
        XCTAssertFalse(status.sleepHeld)
        XCTAssertNil(status.sleepMessage)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        var withoutRunning = object
        withoutRunning.removeValue(forKey: "running")
        XCTAssertThrowsError(try JSONDecoder().decode(HelperStatus.self, from: JSONSerialization.data(withJSONObject: withoutRunning)))
    }

    func testNewStatusFieldsRoundTripAndRejectWrongTypes() throws {
        let status = HelperStatus(state: "Charging", error: nil, settings: Settings(), sample: nil,
                                  backend: "test", chargingAllowed: true, sleepControlAvailable: true,
                                  sleepHeld: true, sleepMessage: "Keeping awake until 80%")
        let encoded = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(HelperStatus.self, from: encoded), status)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["sleepHeld"] = "yes"
        XCTAssertThrowsError(try JSONDecoder().decode(HelperStatus.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
