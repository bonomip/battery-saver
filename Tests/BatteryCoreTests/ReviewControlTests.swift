import XCTest
@testable import BatteryCore

private final class RecoveryHardware: ChargingHardware {
    var operations: [String] = []
    var failures: Set<String> = []
    var chargingAllowed = true
    var adapterEnabled = true
    func adapterSupported() -> Bool { true }
    func setAllowed(_ allowed: Bool) throws {
        try attempt(allowed ? "charge:on" : "charge:off")
        chargingAllowed = allowed
    }
    func setAdapter(_ enabled: Bool) throws {
        try attempt(enabled ? "adapter:on" : "adapter:off")
        adapterEnabled = enabled
    }
    private func attempt(_ operation: String) throws {
        operations.append(operation)
        if failures.contains(operation) { throw SaverError("Injected \(operation) failure") }
    }
}

final class ReviewControlTests: XCTestCase {
    private func sample(_ percent: Int = 50, temperature: Double = 25, ac: Bool = true, age: Double = 0) -> BatterySample {
        BatterySample(date: Date().addingTimeInterval(-age), percent: percent, temperature: temperature,
            externalPower: ac, charging: false, currentMA: 0, voltageMV: 12000, cycles: 1, healthPercent: 90)
    }

    func testRelinquishingFreshSessionDoesNotWriteHardware() throws {
        let hardware = RecoveryHardware()
        let session = ProtectionSession(hardware: hardware)
        try session.relinquish()
        XCTAssertTrue(hardware.operations.isEmpty)
        XCTAssertFalse(session.adapterMayBeDisabled)
    }

    func testRelinquishingCalibrationRestoresOnlyOurAdapterCut() throws {
        let hardware = RecoveryHardware()
        let session = ProtectionSession(hardware: hardware)
        try session.startCalibration()
        _ = try session.update(sample(), settings: Settings())
        XCTAssertTrue(session.adapterMayBeDisabled)
        hardware.operations = []
        try session.relinquish()
        XCTAssertFalse(session.calibration.active)
        XCTAssertFalse(session.adapterMayBeDisabled)
        XCTAssertTrue(hardware.adapterEnabled)
        XCTAssertEqual(hardware.operations, ["adapter:on"])
        try session.relinquish()
        XCTAssertEqual(hardware.operations, ["adapter:on"])
    }

    func testRelinquishRetriesAfterFailedCutAndFailedRestorationWithoutChargeWrites() throws {
        let hardware = RecoveryHardware()
        let session = ProtectionSession(hardware: hardware)
        hardware.failures = ["adapter:off", "adapter:on"]
        try session.startCalibration()
        XCTAssertThrowsError(try session.update(sample(), settings: Settings()))
        XCTAssertTrue(session.adapterMayBeDisabled)
        XCTAssertFalse(session.calibration.active)
        hardware.operations = []
        XCTAssertThrowsError(try session.relinquish())
        XCTAssertTrue(session.adapterMayBeDisabled)
        XCTAssertEqual(hardware.operations, ["adapter:on"])
        hardware.failures = []
        try session.relinquish()
        XCTAssertFalse(session.adapterMayBeDisabled)
        XCTAssertEqual(hardware.operations, ["adapter:on", "adapter:on"])
    }

    func testCalibrationHeatCancellationRetainsThermalPauseUntilCool() throws {
        let hardware = RecoveryHardware(), settings = Settings()
        let session = ProtectionSession(hardware: hardware)
        XCTAssertTrue(try session.update(sample(), settings: settings).allowCharging)
        try session.startCalibration()
        _ = try session.update(sample(), settings: settings)
        XCTAssertFalse(hardware.adapterEnabled)
        XCTAssertThrowsError(try session.update(sample(50, temperature: 40, ac: false), settings: settings))
        XCTAssertFalse(session.calibration.active)
        XCTAssertTrue(hardware.adapterEnabled)
        XCTAssertFalse(hardware.chargingAllowed)
        XCTAssertFalse(try session.update(sample(50, temperature: 37), settings: settings).allowCharging)
        XCTAssertTrue(try session.update(sample(50, temperature: 35), settings: settings).allowCharging)
    }

    func testRecoveryAtUpperLimitRetainsChargePauseInBand() throws {
        let hardware = RecoveryHardware(), settings = Settings()
        let session = ProtectionSession(hardware: hardware)
        _ = try session.update(sample(), settings: settings)
        try session.recover(sample: sample(80, ac: false), settings: settings)
        XCTAssertFalse(hardware.chargingAllowed)
        XCTAssertFalse(try session.update(sample(79), settings: settings).allowCharging)
        XCTAssertTrue(try session.update(sample(75), settings: settings).allowCharging)
    }

    func testFailedCalibrationChargingAboveLimitRestoresOrdinaryCap() throws {
        let hardware = RecoveryHardware(), settings = Settings()
        let session = ProtectionSession(hardware: hardware)
        _ = try session.update(sample(), settings: settings)
        try session.startCalibration()
        _ = try session.update(sample(15), settings: settings)
        hardware.failures = ["charge:on"]
        XCTAssertThrowsError(try session.update(sample(90), settings: settings))
        XCTAssertFalse(session.calibration.active)
        XCTAssertFalse(hardware.chargingAllowed)
        XCTAssertEqual(hardware.operations.last, "charge:off")
    }

    func testSleepStillPausesChargingWhenAdapterRestorationFails() throws {
        let hardware = RecoveryHardware()
        let session = ProtectionSession(hardware: hardware)
        _ = try session.update(sample(), settings: Settings())
        hardware.failures = ["adapter:on"]
        XCTAssertThrowsError(try session.sleep(settings: Settings()))
        XCTAssertFalse(hardware.chargingAllowed)
        XCTAssertEqual(hardware.operations.last, "charge:off")
    }

    func testSleepReportsBothIndependentFailures() {
        let hardware = RecoveryHardware()
        let session = ProtectionSession(hardware: hardware)
        hardware.failures = ["adapter:on", "charge:off"]
        XCTAssertThrowsError(try session.sleep(settings: Settings())) { error in
            XCTAssertTrue(error.localizedDescription.contains("adapter:on"))
            XCTAssertTrue(error.localizedDescription.contains("charge:off"))
        }
        XCTAssertEqual(hardware.operations, ["adapter:on", "charge:off"])
    }

    func testDisabledRecoveryRestoresNormalChargingAndResetsThermalState() throws {
        let hardware = RecoveryHardware()
        let session = ProtectionSession(hardware: hardware)
        _ = try session.update(sample(), settings: Settings())
        try session.recover(sample: sample(100, temperature: 40, age: 300), settings: Settings(enabled: false))
        XCTAssertTrue(hardware.adapterEnabled)
        XCTAssertTrue(hardware.chargingAllowed)
        // Re-enabling starts a fresh policy and waits for a warm battery to cool.
        XCTAssertFalse(try session.update(sample(50, temperature: 37), settings: Settings()).allowCharging)
        XCTAssertTrue(try session.update(sample(50, temperature: 35), settings: Settings()).allowCharging)
    }

    func testDisabledSleepStillAllowsChargingIfAdapterRestorationFails() throws {
        let hardware = RecoveryHardware()
        let session = ProtectionSession(hardware: hardware)
        _ = try session.update(sample(90), settings: Settings())
        hardware.failures = ["adapter:on"]
        XCTAssertThrowsError(try session.sleep(settings: Settings(enabled: false)))
        XCTAssertTrue(hardware.chargingAllowed)
        XCTAssertEqual(hardware.operations.last, "charge:on")
    }
}
