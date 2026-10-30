import XCTest
@testable import BatteryCore

final class ChargingSleepGuardTests: XCTestCase {
    func testAcquisitionFailureDoesNotSpawnRepeatedWritesOnEveryTick() throws {
        let hardware = Hardware(); hardware.failWrite = true
        let subject = ChargingSleepGuard(hardware: hardware)
        XCTAssertThrowsError(try subject.update(status: status()))
        hardware.failWrite = false
        try subject.release()
        XCTAssertThrowsError(try subject.update(status: status()))
        XCTAssertEqual(hardware.writes, [true])
        var off = status(); off.settings.keepAwakeUntilLimit = false
        try subject.update(status: off)
        try subject.update(status: status())
        XCTAssertEqual(hardware.writes, [true, true])
    }
    final class Hardware: SleepSetting {
        var disabled = false
        var writes: [Bool] = []
        var failWrite = false
        var ignoreWrite = false
        var failRead = false
        func isSleepDisabled() throws -> Bool {
            if failRead { throw SaverError("read failed") }
            return disabled
        }
        func setSleepDisabled(_ disabled: Bool) throws {
            writes.append(disabled)
            if failWrite { throw SaverError("write failed") }
            if !ignoreWrite { self.disabled = disabled }
        }
    }
    func status(_ percent: Int = 78) -> HelperStatus {
        HelperStatus(state: "Charging", error: nil, settings: Settings(),
                     sample: BatterySample(date: Date(), percent: percent, temperature: 30,
                                           externalPower: true, charging: false, currentMA: nil,
                                           voltageMV: nil, cycles: nil, healthPercent: nil),
                     backend: "test", chargingAllowed: true)
    }
    func testBelowUpperAcquiresOnceAndUpperReleases() throws {
        let hardware = Hardware()
        var records: [Bool] = []
        let subject = ChargingSleepGuard(hardware: hardware, persistRecovery: { records.append($0) })
        try subject.update(status: status())
        try subject.update(status: status())
        XCTAssertTrue(subject.isHolding)
        XCTAssertEqual(hardware.writes, [true])
        try subject.update(status: status(80))
        XCTAssertFalse(subject.isHolding)
        XCTAssertEqual(hardware.writes, [true, false])
        XCTAssertEqual(records, [true, false])
    }
    func testUnsafeStatesRelease() throws {
        var states: [HelperStatus] = []
        var value = status(); value.settings.enabled = false; states.append(value)
        value = status(); value.settings.keepAwakeUntilLimit = false; states.append(value)
        value = status(); value.error = "failure"; states.append(value)
        value = status(); value.running = false; states.append(value)
        value = status(); value.calibrationActive = true; states.append(value)
        value = status(); value.chargingAllowed = false; states.append(value)
        value = status(); value.sample = nil; states.append(value)
        value = status(); value.sample = sample(power: false); states.append(value)
        value = status(); value.sample = sample(temperature: 38); states.append(value)
        value = status(); value.sample = sample(temperature: .nan); states.append(value)
        value = status(); value.sample = sample(percent: -1); states.append(value)
        value = status(); value.sample?.date = Date(timeIntervalSinceNow: -31); states.append(value)
        for state in states {
            let hardware = Hardware()
            let subject = ChargingSleepGuard(hardware: hardware)
            try subject.update(status: status())
            try subject.update(status: state)
            XCTAssertFalse(subject.isHolding)
            XCTAssertFalse(hardware.disabled)
        }
    }
    private func sample(percent: Int = 78, temperature: Double = 30, power: Bool = true) -> BatterySample {
        BatterySample(date: Date(), percent: percent, temperature: temperature, externalPower: power,
                      charging: false, currentMA: nil, voltageMV: nil, cycles: nil, healthPercent: nil)
    }
    func testExternalSettingPreserved() throws {
        let hardware = Hardware(); hardware.disabled = true
        let subject = ChargingSleepGuard(hardware: hardware)
        try subject.update(status: status())
        try subject.release()
        XCTAssertFalse(subject.isHolding)
        XCTAssertTrue(hardware.disabled)
        XCTAssertTrue(hardware.writes.isEmpty)
    }
    func testCrashRecoveryRestoresBeforeClearingRecord() throws {
        let hardware = Hardware(); hardware.disabled = true
        var marker = true
        let subject = ChargingSleepGuard(hardware: hardware, recoveryRequired: true, persistRecovery: {
            XCTAssertFalse(hardware.disabled); marker = $0
        })
        try subject.recover()
        XCTAssertFalse(marker)
        XCTAssertFalse(subject.isHolding)
    }
    func testAcquisitionFailureRetainsRecovery() throws {
        for ignoreWrite in [false, true] {
            let hardware = Hardware(); hardware.failWrite = !ignoreWrite; hardware.ignoreWrite = ignoreWrite
            var marker = false
            let subject = ChargingSleepGuard(hardware: hardware, persistRecovery: { marker = $0 })
            XCTAssertThrowsError(try subject.update(status: status()))
            XCTAssertTrue(marker)
            XCTAssertTrue(subject.isHolding)
        }
    }
    func testMarkerMustPersistBeforeHardwareWrite() throws {
        let hardware = Hardware()
        let subject = ChargingSleepGuard(hardware: hardware, persistRecovery: { _ in
            throw SaverError("record failed")
        })
        XCTAssertThrowsError(try subject.update(status: status()))
        XCTAssertFalse(subject.isHolding)
        XCTAssertTrue(hardware.writes.isEmpty)
    }
    func testReadFailureRetainsOwnershipForRecovery() throws {
        let hardware = Hardware()
        let subject = ChargingSleepGuard(hardware: hardware)
        try subject.update(status: status())
        hardware.failRead = true
        XCTAssertThrowsError(try subject.release())
        XCTAssertTrue(subject.isHolding)
        hardware.failRead = false
        try subject.release()
        XCTAssertFalse(subject.isHolding)
    }
    func testRecordFailureRetainsOwnershipAndRetries() throws {
        let hardware = Hardware()
        var failClear = true
        let subject = ChargingSleepGuard(hardware: hardware, persistRecovery: {
            if !$0 && failClear { throw SaverError("record failed") }
        })
        try subject.update(status: status())
        XCTAssertThrowsError(try subject.release())
        XCTAssertTrue(subject.isHolding)
        XCTAssertFalse(hardware.disabled)
        failClear = false
        try subject.release()
        XCTAssertFalse(subject.isHolding)
    }
    func testNoProgressBlocksUntilIneligible() throws {
        let hardware = Hardware(); var now: TimeInterval = 0
        let subject = ChargingSleepGuard(hardware: hardware, uptime: { now })
        try subject.update(status: status())
        now = 1800
        XCTAssertThrowsError(try subject.update(status: status()))
        XCTAssertFalse(hardware.disabled)
        XCTAssertThrowsError(try subject.update(status: status()))
        try subject.update(status: status(80))
        try subject.update(status: status())
        XCTAssertTrue(subject.isHolding)
    }
    func testEightHourBoundDespiteProgress() throws {
        let hardware = Hardware(); var now: TimeInterval = 0
        let subject = ChargingSleepGuard(hardware: hardware, uptime: { now })
        try subject.update(status: status(20))
        for index in 1...28 {
            now = Double(index * 1000)
            try subject.update(status: status(20 + index))
        }
        now = 28800
        XCTAssertThrowsError(try subject.update(status: status(49)))
        XCTAssertFalse(subject.isHolding)
    }
    func testExternalOverrideAndReverseClockBlockReacquisition() throws {
        for reverse in [false, true] {
            let hardware = Hardware(); var now: TimeInterval = 100
            let subject = ChargingSleepGuard(hardware: hardware, uptime: { now })
            try subject.update(status: status())
            if reverse { now = 99 } else { hardware.disabled = false }
            XCTAssertThrowsError(try subject.update(status: status()))
            XCTAssertFalse(subject.isHolding)
            XCTAssertThrowsError(try subject.update(status: status()))
            XCTAssertEqual(hardware.writes.filter { $0 }.count, 1)
        }
    }
}
