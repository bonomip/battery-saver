import XCTest
@testable import BatteryCore

final class BatteryInsightsTests: XCTestCase {
    func testNegativeCurrentDoesNotPretendChargingWhileDrainEvidenceSettles() {
        var state = BatteryInsights()
        let first = update(&state, reading(charging: true), now: 0)
        XCTAssertEqual(first.activity, .pluggedIn)
        XCTAssertNil(first.estimate)
        XCTAssertEqual(update(&state, reading(1, charging: true), now: 1).activity, .pluggedInDraining)
    }
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func reading(_ offset: Double = 0, current: Int = -500, ac: Bool = true, charging: Bool = false, remaining: Double = 3000, full: Double = 5000, percent: Int = 60, osFull: Int? = nil, osEmpty: Int? = nil) -> (BatterySample, BatteryTelemetry) {
        let sample = BatterySample(date: start.addingTimeInterval(offset), percent: percent, temperature: 25, externalPower: ac, charging: charging, currentMA: current, voltageMV: nil, cycles: nil, healthPercent: nil)
        return (sample, BatteryTelemetry(sensorDate: sample.date, currentMA: current, remainingMAH: remaining, fullMAH: full, percent: percent, externalPower: ac, charging: charging, minutesToFull: osFull, minutesToEmpty: osEmpty))
    }
    private func update(_ state: inout BatteryInsights, _ reading: (BatterySample, BatteryTelemetry), now: Double, target: Int = 80) -> BatteryInsightResult {
        state.update(sample: reading.0, telemetry: reading.1, targetPercent: target, now: start.addingTimeInterval(now), uptime: now + 1000)
    }
    func testDrainNeedsDistinctFreshUpdatesAndClearsWithStaleness() {
        var state = BatteryInsights()
        let first = reading()
        XCTAssertEqual(update(&state, first, now: 0).activity, .pluggedIn)
        XCTAssertEqual(update(&state, first, now: 5).activity, .pluggedIn)
        let result = update(&state, reading(10), now: 10)
        XCTAssertEqual(result.activity, .pluggedInDraining)
        XCTAssertEqual(result.estimate, "About 6h remaining")
        XCTAssertEqual(update(&state, reading(10), now: 101).activity, .pluggedIn)
    }
    func testNoiseThresholdRecoveryContradictoryChargingAndReconnect() {
        var state = BatteryInsights()
        _ = update(&state, reading(current: -100), now: 0)
        XCTAssertEqual(update(&state, reading(1), now: 1).activity, .pluggedIn)
        XCTAssertEqual(update(&state, reading(2, charging: true), now: 2).activity, .pluggedInDraining)
        XCTAssertEqual(update(&state, reading(3, current: -50), now: 3).activity, .pluggedIn)
        _ = update(&state, reading(4, ac: false), now: 4)
        XCTAssertEqual(update(&state, reading(5), now: 5).activity, .pluggedIn)
        XCTAssertEqual(BatteryActivity.pluggedInDraining.tone(percent: 15), .yellow)
        XCTAssertEqual(BatteryActivity.pluggedInDraining.tone(percent: 16), .yellow)
        XCTAssertFalse(BatteryActivity.pluggedInDraining.isCharging)
    }
    func testCustomTargetUsesCapacityAndTwoReadingsNeverScalesOS() {
        var state = BatteryInsights()
        XCTAssertEqual(update(&state, reading(current: 1000, charging: true, osFull: 300), now: 0).estimate, "Estimating…")
        XCTAssertEqual(update(&state, reading(10, current: 1000, charging: true, osFull: 300), now: 10).estimate, "About 1h to 80%")
        XCTAssertNil(update(&state, reading(20, current: 1000, charging: true), now: 20, target: 50).estimate)
    }
    func testInvalidCapacitiesSleepAndClockReversalResetRate() {
        var state = BatteryInsights()
        _ = update(&state, reading(current: 1000, charging: true), now: 0)
        XCTAssertEqual(update(&state, reading(10, current: 1000, charging: true, full: 0), now: 10).estimate, "Estimating…")
        XCTAssertEqual(update(&state, reading(400, current: 1000, charging: true), now: 400).estimate, "Estimating…")
        XCTAssertEqual(update(&state, reading(5, current: 1000, charging: true), now: 5).estimate, "Estimating…")
    }
    func testOperatingSystemEstimatesOnlyInCompatibleStates() {
        var state = BatteryInsights()
        XCTAssertEqual(update(&state, reading(current: 1000, charging: true, osFull: 43), now: 0, target: 100).estimate, "About 45 min to 100%")
        XCTAssertEqual(update(&state, reading(1, ac: false, osEmpty: 120), now: 1).estimate, "About 2h remaining")
        XCTAssertEqual(update(&state, reading(2, ac: false, osEmpty: 65535), now: 2).estimate, "About 6h remaining")
    }
    func testFutureAndOldSensorsNeverConfirmDrain() {
        for offset in [-91.0, 1.0] {
            var state = BatteryInsights()
            XCTAssertEqual(update(&state, reading(offset), now: 0).activity, .pluggedIn)
            XCTAssertEqual(update(&state, reading(offset + 1), now: 0).activity, .pluggedIn)
        }
    }
    func testInvalidOperatingSystemTimesAndImplausibleRatesStayEstimating() {
        for invalid in [-1, 0, 65535, 3000] {
            var state = BatteryInsights()
            XCTAssertEqual(update(&state, reading(current: 1000, charging: true, osFull: invalid), now: 0, target: 100).estimate, "Estimating…")
        }
        var state = BatteryInsights()
        _ = update(&state, reading(current: 101, charging: true, remaining: 100, full: 100_000), now: 0)
        XCTAssertEqual(update(&state, reading(1, current: 101, charging: true, remaining: 100, full: 100_000), now: 1).estimate, "Estimating…")
    }
    func testIdleHasNoEstimateAndTargetChangeResetsEvidence() {
        var state = BatteryInsights()
        XCTAssertNil(update(&state, reading(current: 0, osFull: 60), now: 0).estimate)
        _ = update(&state, reading(1, current: 1000, charging: true), now: 1)
        XCTAssertEqual(update(&state, reading(2, current: 1000, charging: true), now: 2, target: 90).estimate, "Estimating…")
    }

    func testCustomTargetUsesDisplayedPercentWhenRawStateOfChargeDiffers() {
        var state = BatteryInsights()
        _ = update(&state, reading(current: 1000, charging: true, remaining: 2000), now: 0)
        XCTAssertEqual(update(&state, reading(10, current: 1000, charging: true, remaining: 2000), now: 10).estimate, "About 1h to 80%")
    }
    func testStaleOperatingSystemEstimatesAreRejected() {
        var state = BatteryInsights()
        XCTAssertEqual(update(&state, reading(current: 1000, charging: true, osFull: 30), now: 91, target: 100).estimate, "Estimating…")
        XCTAssertEqual(update(&state, reading(100, ac: false, osEmpty: 30), now: 191).estimate, "Estimating…")
    }
    func testPowerChangeDiscardsPreTransitionSensorEvidence() {
        var state = BatteryInsights()
        _ = update(&state, reading(ac: false), now: 0)
        XCTAssertEqual(update(&state, reading(5), now: 10).activity, .pluggedIn)
        XCTAssertEqual(update(&state, reading(11), now: 11).activity, .pluggedIn)
        XCTAssertEqual(update(&state, reading(12), now: 12).activity, .pluggedInDraining)
        _ = update(&state, reading(13, ac: false), now: 13)
        XCTAssertEqual(update(&state, reading(12), now: 14).activity, .pluggedIn)
        XCTAssertEqual(update(&state, reading(15), now: 15).activity, .pluggedIn)
    }
    func testImplausibleCurrentDoesNotConfirmDrain() {
        var state = BatteryInsights()
        for current in [Int.min, -30_001] {
            _ = update(&state, reading(current: current), now: 0)
            XCTAssertEqual(update(&state, reading(1, current: current), now: 1).activity, .pluggedIn)
        }
        XCTAssertEqual(update(&state, reading(2), now: 2).activity, .pluggedIn)
        XCTAssertEqual(update(&state, reading(3), now: 3).activity, .pluggedInDraining)
    }
    func testInconsistentTelemetryCannotAccumulateEvidenceOrShowOSPrediction() {
        var state = BatteryInsights()
        XCTAssertNil(update(&state, reading(current: 1000, charging: true, percent: -1, osFull: 30), now: 0, target: 100).estimate)
        var mismatch = reading(current: 1000, charging: true, osFull: 30)
        mismatch.1.externalPower = false
        XCTAssertNil(update(&state, mismatch, now: 0, target: 100).estimate)
        mismatch = reading(1)
        mismatch.1.percent = 101
        XCTAssertEqual(update(&state, mismatch, now: 1).activity, .pluggedIn)
        XCTAssertEqual(update(&state, reading(2), now: 2).activity, .pluggedIn)
    }

}
