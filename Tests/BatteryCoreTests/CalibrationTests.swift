import XCTest
@testable import BatteryCore

final class CalibrationTests: XCTestCase {
    let start = Date()
    func reading(_ percentage: Int, at date: Date, ac: Bool = true, temperature: Double = 25) -> BatterySample {
        BatterySample(date: date, percent: percentage, temperature: temperature, externalPower: ac, charging: false, currentMA: 0, voltageMV: 12000, cycles: 1, healthPercent: 90)
    }
    func testCompleteCycleAndRestore() throws {
        var calibration = Calibration(); calibration.start(now: start, uptime: 0)
        XCTAssertFalse(try XCTUnwrap(calibration.step(reading(80, at: start), settings: Settings(), now: start, uptime: 0)).useAdapter)
        XCTAssertTrue(try XCTUnwrap(calibration.step(reading(15, at: start), settings: Settings(), now: start, uptime: 0)).useAdapter)
        XCTAssertEqual(calibration.phase, .charging)
        _ = try calibration.step(reading(100, at: start), settings: Settings(), now: start, uptime: 0)
        XCTAssertEqual(calibration.phase, .holding)
        let later = start.addingTimeInterval(3599)
        XCTAssertNotNil(try calibration.step(reading(100, at: later), settings: Settings(), now: later, uptime: later.timeIntervalSince(start)))
        let finish = start.addingTimeInterval(3600)
        XCTAssertNil(try calibration.step(reading(100, at: finish), settings: Settings(), now: finish, uptime: finish.timeIntervalSince(start)))
        XCTAssertEqual(calibration.phase, .completed)
    }
    func testUnplugHeatAndStaleReadingsCancel() {
        for sample in [reading(50, at: start, temperature: 40), reading(50, at: start.addingTimeInterval(-60))] {
            var calibration = Calibration(); calibration.start(now: start, uptime: 0)
            XCTAssertThrowsError(try calibration.step(sample, settings: Settings(), now: start, uptime: 0))
            XCTAssertFalse(calibration.active)
        }
    }
    func testAdapterCutIsExpectedOnlyDuringDischarge() throws {
        var calibration = Calibration(); calibration.start(now: start, uptime: 0)
        XCTAssertNotNil(try calibration.step(reading(50, at: start, ac: false), settings: Settings(), now: start, uptime: 0))
        _ = try calibration.step(reading(15, at: start, ac: false), settings: Settings(), now: start, uptime: 0)
        XCTAssertThrowsError(try calibration.step(reading(15, at: start, ac: false), settings: Settings(), now: start, uptime: 0))
        XCTAssertFalse(calibration.active)
    }
    func testTimeoutAndExplicitCancellation() throws {
        var calibration = Calibration(); calibration.start(now: start, uptime: 0)
        let later = start.addingTimeInterval(86401)
        XCTAssertThrowsError(try calibration.step(reading(50, at: later), settings: Settings(), now: later, uptime: later.timeIntervalSince(start)))
        calibration.start(now: later, uptime: later.timeIntervalSince(start)); calibration.cancel()
        XCTAssertNil(try calibration.step(reading(50, at: later), settings: Settings(), now: later, uptime: later.timeIntervalSince(start)))
    }
    func testHoldMustBeContinuousAtFull() throws {
        var calibration = Calibration(); calibration.start(now: start, uptime: 0)
        _ = try calibration.step(reading(15, at: start), settings: Settings(), now: start, uptime: 0)
        _ = try calibration.step(reading(100, at: start), settings: Settings(), now: start, uptime: 0)
        _ = try calibration.step(reading(99, at: start), settings: Settings(), now: start, uptime: 0)
        XCTAssertEqual(calibration.phase, .charging)
        XCTAssertNil(calibration.holdStarted)
    }
    func testWallClockJumpCannotShortenHoldingPeriod() throws {
        var calibration = Calibration(); calibration.start(now: start, uptime: 100)
        _ = try calibration.step(reading(15, at: start), settings: Settings(), now: start, uptime: 100)
        _ = try calibration.step(reading(100, at: start), settings: Settings(), now: start, uptime: 100)
        let changedWallClock = start.addingTimeInterval(7200)
        XCTAssertNotNil(try calibration.step(reading(100, at: changedWallClock), settings: Settings(), now: changedWallClock, uptime: 160))
        XCTAssertEqual(calibration.phase, .holding)
        let changedBack = start.addingTimeInterval(-7200)
        XCTAssertNil(try calibration.step(reading(100, at: changedBack), settings: Settings(), now: changedBack, uptime: 3700))
        XCTAssertEqual(calibration.phase, .completed)
    }
    func testWallClockJumpDoesNotTriggerDurationTimeoutButUptimeResetCancels() throws {
        var calibration = Calibration(); calibration.start(now: start, uptime: 100)
        let tomorrow = start.addingTimeInterval(90000)
        XCTAssertNotNil(try calibration.step(reading(50, at: tomorrow), settings: Settings(), now: tomorrow, uptime: 160))
        XCTAssertThrowsError(try calibration.step(reading(50, at: tomorrow), settings: Settings(), now: tomorrow, uptime: 99))
        XCTAssertFalse(calibration.active)
    }
}
