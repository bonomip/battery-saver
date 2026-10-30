import XCTest
@testable import BatteryCore

final class PolicyTests: XCTestCase {
    func sample(_ charge: Int = 77, _ temperature: Double = 30, ac: Bool = true, age: Double = 0) -> BatterySample {
        BatterySample(date: Date().addingTimeInterval(-age), percent: charge, temperature: temperature, externalPower: ac, charging: false, currentMA: 0, voltageMV: 12000, cycles: 432, healthPercent: 86)
    }
    func testChargeBoundariesAndHysteresis() throws {
        var policy = ChargePolicy()
        let settings = Settings()
        XCTAssertTrue(try policy.evaluate(sample(74), settings: settings).allowCharging)
        XCTAssertTrue(try policy.evaluate(sample(79), settings: settings).allowCharging)
        XCTAssertFalse(try policy.evaluate(sample(80), settings: settings).allowCharging)
        XCTAssertFalse(try policy.evaluate(sample(79), settings: settings).allowCharging)
        XCTAssertFalse(try policy.evaluate(sample(76), settings: settings).allowCharging)
        XCTAssertTrue(try policy.evaluate(sample(75), settings: settings).allowCharging)
    }
    func testStartupInBandDoesNotTopUp() throws {
        var policy = ChargePolicy()
        XCTAssertFalse(try policy.evaluate(sample(), settings: Settings()).allowCharging)
    }
    func testRestartWhileWarmWaitsUntilCool() throws {
        var policy = ChargePolicy()
        XCTAssertFalse(try policy.evaluate(sample(50, 37), settings: Settings()).allowCharging)
        XCTAssertTrue(try policy.evaluate(sample(50, 35), settings: Settings()).allowCharging)
    }
    func testHeatLatchAcrossChargeTransitionsAndCooling() throws {
        var policy = ChargePolicy()
        let settings = Settings()
        XCTAssertFalse(try policy.evaluate(sample(50, 38), settings: settings).allowCharging)
        XCTAssertFalse(try policy.evaluate(sample(50, 36), settings: settings).allowCharging)
        XCTAssertTrue(try policy.evaluate(sample(50, 35), settings: settings).allowCharging)
        XCTAssertFalse(try policy.evaluate(sample(83, 35), settings: settings).allowCharging)
        XCTAssertTrue(try policy.evaluate(sample(50, 35), settings: settings).allowCharging)
    }
    func testMissingInvalidAndStaleReadingsAreRejected() {
        for reading in [sample(-1), sample(101), sample(50, .nan), sample(50, -40), sample(age: 90)] {
            var policy = ChargePolicy()
            XCTAssertThrowsError(try policy.evaluate(reading, settings: Settings()))
        }
    }
    func testInvalidSettingsAreRejected() {
        for settings in [Settings(lower: 80, upper: 80), Settings(lower: 5), Settings(upper: 101), Settings(heatPause: .nan), Settings(heatPause: 38, heatResume: 38)] {
            XCTAssertThrowsError(try settings.validate())
        }
    }
    func testDisabledRestoresControlEvenWithStaleReadings() throws {
        var policy = ChargePolicy()
        XCTAssertTrue(try policy.evaluate(sample(age: 300), settings: Settings(enabled: false)).allowCharging)
    }
    func testUnplugAndReplugPreservesHeatProtection() throws {
        var policy = ChargePolicy()
        XCTAssertFalse(try policy.evaluate(sample(50, 40), settings: Settings()).allowCharging)
        XCTAssertTrue(try policy.evaluate(sample(50, 37, ac: false), settings: Settings()).allowCharging)
        XCTAssertFalse(try policy.evaluate(sample(50, 37), settings: Settings()).allowCharging)
    }
    func testTemperatureConversionAndValidation() throws {
        XCTAssertEqual(try BatteryReader.celsius(raw: 2984), 25.25, accuracy: 0.01)
        XCTAssertThrowsError(try BatteryReader.celsius(raw: 0))
        XCTAssertThrowsError(try BatteryReader.celsius(raw: .nan))
    }
    func testStatusCannotClaimActiveWhenStaleOrFailed() {
        let status = HelperStatus(date: Date().addingTimeInterval(-40), state: "Paused", error: nil, settings: Settings(), sample: sample(), backend: "legacy", chargingAllowed: false)
        XCTAssertFalse(status.isCurrent)
        var failed = status
        failed.date = Date()
        failed.error = "Hardware write failed"
        XCTAssertFalse(failed.isCurrent)
    }
}
