import XCTest
@testable import BatteryCore

private final class FakeHardware: ChargingHardware {
    var operations: [String] = []
    var supportsAdapter = true
    var fail: String?
    func adapterSupported() -> Bool { supportsAdapter }
    func perform(_ operation: String) throws {
        operations.append(operation)
        if operation == fail { throw SaverError("Injected \(operation) failure") }
    }
    func setAllowed(_ allowed: Bool) throws { try perform(allowed ? "charge:on" : "charge:off") }
    func setAdapter(_ enabled: Bool) throws { try perform(enabled ? "adapter:on" : "adapter:off") }
}

final class SessionTests: XCTestCase {
    func sample(_ percent: Int = 50, temperature: Double = 25) -> BatterySample {
        BatterySample(date: Date(), percent: percent, temperature: temperature, externalPower: true, charging: false, currentMA: 0, voltageMV: 12000, cycles: 1, healthPercent: 90)
    }
    func testRegularPolicyNeverDisablesAdapter() throws {
        let hardware = FakeHardware(); let session = ProtectionSession(hardware: hardware)
        for level in [50, 79, 80, 79, 76, 75] { _ = try session.update(sample(level), settings: Settings()) }
        XCTAssertFalse(hardware.operations.contains("adapter:off"))
        XCTAssertEqual(hardware.operations.filter { $0.hasPrefix("charge:") }, ["charge:on", "charge:on", "charge:off", "charge:off", "charge:off", "charge:on"])
    }
    func testCalibrationDisablesChargeBeforeAdapterAndReversesOrderAt15() throws {
        let hardware = FakeHardware(); let session = ProtectionSession(hardware: hardware)
        try session.startCalibration()
        _ = try session.update(sample(), settings: Settings())
        XCTAssertEqual(hardware.operations, ["charge:off", "adapter:off"])
        hardware.operations = []
        _ = try session.update(sample(15), settings: Settings())
        XCTAssertEqual(hardware.operations, ["adapter:on", "charge:on"])
    }
    func testCancellationRestoresAdapterBeforeNormalPolicy() throws {
        let hardware = FakeHardware(); let session = ProtectionSession(hardware: hardware)
        try session.startCalibration()
        _ = try session.update(sample(), settings: Settings())
        session.cancelCalibration(); hardware.operations = []
        _ = try session.update(sample(83), settings: Settings())
        XCTAssertEqual(hardware.operations, ["adapter:on", "charge:off"])
    }
    func testSleepCancelsCalibrationAndPausesChargingWithoutBlockingSleep() throws {
        let hardware = FakeHardware(); let session = ProtectionSession(hardware: hardware)
        try session.startCalibration()
        try session.sleep(settings: Settings())
        XCTAssertFalse(session.calibration.active)
        XCTAssertEqual(hardware.operations, ["adapter:on", "charge:off"])
    }
    func testDisabledSleepAllowsNormalCharging() throws {
        let hardware = FakeHardware(); let session = ProtectionSession(hardware: hardware)
        try session.sleep(settings: Settings(enabled: false))
        XCTAssertEqual(hardware.operations, ["adapter:on", "charge:on"])
    }
    func testFailedDischargeAttemptsRestorationAndReportsError() throws {
        let hardware = FakeHardware(); let session = ProtectionSession(hardware: hardware)
        hardware.fail = "adapter:off"
        try session.startCalibration()
        XCTAssertThrowsError(try session.update(sample(), settings: Settings()))
        XCTAssertEqual(hardware.operations, ["charge:off", "adapter:off", "adapter:on", "charge:on"])
        XCTAssertFalse(session.calibration.active)
    }
    func testRestorationAttemptsBothGatesAndReportsFailure() {
        let hardware = FakeHardware(); let session = ProtectionSession(hardware: hardware)
        hardware.fail = "adapter:on"
        XCTAssertThrowsError(try session.restore())
        XCTAssertEqual(hardware.operations, ["adapter:on", "charge:on"])
    }
    func testInvalidSampleRestoresInsteadOfClaimingProtection() {
        let hardware = FakeHardware(); let session = ProtectionSession(hardware: hardware)
        XCTAssertThrowsError(try session.update(sample(200), settings: Settings()))
        XCTAssertEqual(hardware.operations.suffix(2), ["adapter:on", "charge:on"])
    }
    func testUnsupportedAdapterStillAllowsNormalLimitButNotCalibration() throws {
        let hardware = FakeHardware(); hardware.supportsAdapter = false
        let session = ProtectionSession(hardware: hardware)
        XCTAssertThrowsError(try session.startCalibration())
        _ = try session.update(sample(85), settings: Settings())
        XCTAssertEqual(hardware.operations, ["charge:off"])
    }
    func testDisablingProtectionCancelsAndRestores() throws {
        let hardware = FakeHardware(); let session = ProtectionSession(hardware: hardware)
        try session.startCalibration()
        _ = try session.update(sample(), settings: Settings(enabled: false))
        XCTAssertFalse(session.calibration.active)
        XCTAssertEqual(hardware.operations, ["adapter:on", "charge:on"])
    }
    func testHelperRestartDoesNotResumeCalibration() throws {
        let hardware = FakeHardware(); let session = ProtectionSession(hardware: hardware)
        try session.startCalibration()
        _ = try session.update(sample(), settings: Settings())
        let restarted = ProtectionSession(hardware: hardware)
        hardware.operations = []
        _ = try restarted.update(sample(77), settings: Settings())
        XCTAssertFalse(restarted.calibration.active)
        XCTAssertEqual(hardware.operations, ["adapter:on", "charge:off"])
    }
    func testThermalCalibrationCancellationKeepsChargingPaused() throws {
        let hardware = FakeHardware(); let session = ProtectionSession(hardware: hardware)
        try session.startCalibration()
        XCTAssertThrowsError(try session.update(sample(50, temperature: 40), settings: Settings()))
        XCTAssertFalse(session.calibration.active)
        XCTAssertEqual(hardware.operations.suffix(2), ["adapter:on", "charge:off"])
    }
    func testThermalRecoveryStillAttemptsChargePauseIfAdapterRestoreFails() {
        let hardware = FakeHardware(); hardware.fail = "adapter:on"
        let session = ProtectionSession(hardware: hardware)
        XCTAssertThrowsError(try session.recover(sample: sample(50, temperature: 40), settings: Settings()))
        XCTAssertEqual(hardware.operations, ["adapter:on", "charge:off"])
    }
    func testRepeatedStartDoesNotRestartOrCancelAnActiveCalibration() throws {
        let hardware = FakeHardware(); let session = ProtectionSession(hardware: hardware)
        try session.startCalibration()
        _ = try session.update(sample(15), settings: Settings())
        XCTAssertEqual(session.calibration.phase, .charging)
        try session.startCalibration()
        XCTAssertEqual(session.calibration.phase, .charging)
    }
}
