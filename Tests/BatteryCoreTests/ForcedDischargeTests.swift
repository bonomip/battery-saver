import XCTest
@testable import BatteryCore

private final class DischargeHardware: ChargingHardware {
    var operations: [String] = []
    var supportsAdapter = true
    var fail: String?
    func adapterSupported() -> Bool { supportsAdapter }
    func record(_ value: String) throws {
        operations.append(value)
        if value == fail { throw SaverError("Injected failure") }
    }
    func setAllowed(_ value: Bool) throws { try record("charge:\(value)") }
    func setAdapter(_ value: Bool) throws { try record("adapter:\(value)") }
}

final class ForcedDischargeTests: XCTestCase {
    func testSessionCommandsStartAndCancelAndStayCancelled() {
        let hardware = DischargeHardware()
        var recovery = false
        let controller = HelperController(hardware: hardware, backend: "test", existingCommand: nil,
            readSettings: { Settings() }, readBattery: { self.sample() }, checkConflict: { false },
            readCommand: { nil }, persistAdapterRecovery: { recovery = $0 })
        let start = DischargeCommand(target: 80)
        let running = controller.tick(dischargeRequest: start)
        XCTAssertEqual(running.dischargeTarget, 80)
        XCTAssertEqual(running.dischargeCommandID, start.id)
        XCTAssertTrue(running.adapterRecoveryRequired)
        XCTAssertTrue(recovery)
        XCTAssertEqual(controller.tick().dischargeTarget, 80)
        let cancel = DischargeCommand(target: nil)
        let stopped = controller.tick(dischargeRequest: cancel)
        XCTAssertNil(stopped.error)
        XCTAssertNil(stopped.dischargeTarget)
        XCTAssertEqual(stopped.dischargeCommandID, cancel.id)
        XCTAssertFalse(stopped.adapterRecoveryRequired)
        XCTAssertFalse(recovery)
        XCTAssertNil(controller.tick().dischargeTarget)
        XCTAssertTrue(hardware.operations.contains("adapter:true"))
    }
    func testFailedRestorationRemainsVisibleAndRestartRetriesWithoutReplayingDischarge() {
        let hardware = DischargeHardware()
        var recovery = false
        func controller() -> HelperController {
            HelperController(hardware: hardware, backend: "test", existingCommand: nil,
                readSettings: { Settings() }, readBattery: { self.sample() }, checkConflict: { false },
                readCommand: { nil }, adapterRecoveryRequired: recovery,
                persistAdapterRecovery: { recovery = $0 })
        }
        let first = controller()
        _ = first.tick(dischargeRequest: DischargeCommand(target: 80))
        hardware.fail = "adapter:true"
        let stopped = first.stop()
        XCTAssertNotNil(stopped.error)
        XCTAssertNil(stopped.dischargeTarget)
        XCTAssertTrue(stopped.adapterRecoveryRequired)
        XCTAssertTrue(recovery)
        hardware.fail = nil
        let recovered = controller().stop()
        XCTAssertNil(recovered.error)
        XCTAssertNil(recovered.dischargeTarget)
        XCTAssertFalse(recovered.adapterRecoveryRequired)
        XCTAssertFalse(recovery)
        XCTAssertEqual(recovered.settings, Settings())
    }
    private let now = Date()
    private func sample(_ percent: Int = 90, temperature: Double = 25, external: Bool = true, date: Date = Date()) -> BatterySample {
        BatterySample(date: date, percent: percent, temperature: temperature, externalPower: external,
                      charging: false, currentMA: -500, voltageMV: 12000, cycles: 1, healthPercent: 90)
    }
    func testTargetAndOvershootRestoreNormalPolicy() throws {
        for final in [80, 79, 74] {
            let hardware = DischargeHardware()
            let session = ProtectionSession(hardware: hardware)
            try session.startDischarge(sample: sample(), settings: Settings(), target: 80)
            XCTAssertFalse(try session.update(sample(), settings: Settings()).allowCharging)
            XCTAssertEqual(hardware.operations, ["charge:false", "adapter:false"])
            hardware.operations = []
            let decision = try session.update(sample(final, external: false), settings: Settings())
            XCTAssertFalse(session.discharge.active)
            XCTAssertFalse(session.adapterMayBeDisabled)
            XCTAssertEqual(hardware.operations.first, "adapter:true")
            XCTAssertEqual(decision.allowCharging, final <= 75)
        }
    }
    func testEntryRejectsInvalidStatesWithoutHardwareWrites() throws {
        for reading in [sample(80), sample(79), sample(101), sample(90, temperature: .nan), sample(90, temperature: 36), sample(90, external: false), sample(90, date: Date(timeIntervalSinceNow: -31))] {
            let hardware = DischargeHardware(); let session = ProtectionSession(hardware: hardware)
            XCTAssertThrowsError(try session.startDischarge(sample: reading, settings: Settings(), target: 80))
            XCTAssertTrue(hardware.operations.isEmpty)
        }
        var mode = ForcedDischarge()
        XCTAssertThrowsError(try mode.start(sample: sample(), settings: Settings(enabled: false), target: 80))
        XCTAssertThrowsError(try mode.start(sample: sample(), settings: Settings(), target: 81))
    }
    func testExpectedAdapterCutDoesNotCancel() throws {
        var mode = ForcedDischarge()
        try mode.start(sample: sample(date: now), settings: Settings(), target: 80, now: now, uptime: 10)
        XCTAssertTrue(try mode.step(sample: sample(89, external: false, date: now), settings: Settings(), now: now, uptime: 11))
        XCTAssertTrue(mode.active)
    }
    func testTimeoutAndClockBoundaries() throws {
        for elapsed in [1800.0, 8 * 3600.0, -1.0, Double.nan] {
            var mode = ForcedDischarge()
            try mode.start(sample: sample(date: now), settings: Settings(), target: 80, now: now, uptime: 10)
            XCTAssertThrowsError(try mode.step(sample: sample(date: now), settings: Settings(), now: now, uptime: 10 + elapsed))
            XCTAssertFalse(mode.active)
        }
        var mode = ForcedDischarge()
        try mode.start(sample: sample(date: now), settings: Settings(), target: 80, now: now, uptime: 0)
        XCTAssertTrue(try mode.step(sample: sample(89, date: now), settings: Settings(), now: now, uptime: 1799))
        XCTAssertTrue(try mode.step(sample: sample(89, date: now), settings: Settings(), now: now, uptime: 1800))
        XCTAssertThrowsError(try mode.step(sample: sample(89, date: now), settings: Settings(), now: now, uptime: 3599))
    }
    func testSettingsChangeCancelsAndRestores() throws {
        let hardware = DischargeHardware(); let session = ProtectionSession(hardware: hardware)
        try session.startDischarge(sample: sample(), settings: Settings(), target: 80)
        _ = try session.update(sample(), settings: Settings())
        hardware.operations = []
        _ = try session.update(sample(89, external: false), settings: Settings(upper: 85))
        XCTAssertFalse(session.discharge.active)
        XCTAssertEqual(hardware.operations, ["adapter:true", "charge:false"])
    }
    func testMutualExclusionAndUnsupportedHardware() throws {
        let hardware = DischargeHardware(); let session = ProtectionSession(hardware: hardware)
        try session.startDischarge(sample: sample(), settings: Settings(), target: 80)
        XCTAssertThrowsError(try session.startCalibration())
        session.cancelDischarge()
        try session.startCalibration()
        XCTAssertThrowsError(try session.startDischarge(sample: sample(), settings: Settings(), target: 80))
        hardware.supportsAdapter = false
        let unsupported = ProtectionSession(hardware: hardware)
        XCTAssertThrowsError(try unsupported.startDischarge(sample: sample(), settings: Settings(), target: 80))
    }
    func testDurableIntentPrecedesCutAndRecoveryRetainsOwnershipOnFailure() throws {
        let hardware = DischargeHardware()
        var persisted: [Bool] = []
        let session = ProtectionSession(hardware: hardware, persistAdapterRecovery: { value in
            if value { XCTAssertEqual(hardware.operations, ["charge:false"]) }
            persisted.append(value)
        })
        try session.startDischarge(sample: sample(), settings: Settings(), target: 80)
        _ = try session.update(sample(), settings: Settings())
        XCTAssertEqual(persisted, [true])
        hardware.fail = "adapter:true"
        session.cancelDischarge()
        XCTAssertThrowsError(try session.update(sample(), settings: Settings()))
        XCTAssertTrue(session.adapterMayBeDisabled)
        XCTAssertEqual(persisted, [true])
        hardware.fail = nil
        _ = try session.update(sample(), settings: Settings())
        XCTAssertFalse(session.adapterMayBeDisabled)
        XCTAssertEqual(persisted, [true, false])
    }
    func testFailedIntentNeverCutsAdapter() throws {
        let hardware = DischargeHardware()
        let session = ProtectionSession(hardware: hardware, persistAdapterRecovery: { _ in throw SaverError("disk") })
        try session.startDischarge(sample: sample(), settings: Settings(), target: 80)
        XCTAssertThrowsError(try session.update(sample(), settings: Settings()))
        XCTAssertFalse(hardware.operations.contains("adapter:false"))
        XCTAssertFalse(session.discharge.active)
    }
    func testSleepAndThermalFailureRestoreAdapter() throws {
        for sleep in [true, false] {
            let hardware = DischargeHardware(); let session = ProtectionSession(hardware: hardware)
            try session.startDischarge(sample: sample(), settings: Settings(), target: 80)
            _ = try session.update(sample(), settings: Settings())
            hardware.operations = []
            if sleep { try session.sleep(settings: Settings()) }
            else { XCTAssertThrowsError(try session.update(sample(89, temperature: 38), settings: Settings())) }
            XCTAssertFalse(session.discharge.active)
            XCTAssertFalse(session.adapterMayBeDisabled)
            XCTAssertEqual(hardware.operations.first, "adapter:true")
        }
    }
    func testControllerStopClearsOperation() throws {
        let hardware = DischargeHardware()
        let command = DischargeCommand(target: 80)
        let controller = HelperController(hardware: hardware, backend: "test", existingCommand: nil,
            readSettings: { Settings() }, readBattery: { self.sample() }, checkConflict: { false }, readCommand: { nil })
        XCTAssertEqual(controller.tick(dischargeRequest: command).dischargeTarget, 80)
        let stopped = controller.stop()
        XCTAssertNil(stopped.dischargeTarget)
        XCTAssertFalse(stopped.running)
        XCTAssertEqual(hardware.operations.suffix(2), ["adapter:true", "charge:true"])
    }
    func testSimultaneousStartsRejectedAndCancelWins() {
        for cancel in [true, false] {
            let hardware = DischargeHardware()
            let controller = HelperController(hardware: hardware, backend: "test", existingCommand: nil,
                readSettings: { Settings() }, readBattery: { self.sample() }, checkConflict: { false },
                readCommand: { CalibrationCommand(start: !cancel) })
            let status = controller.tick(dischargeRequest: DischargeCommand(target: 80))
            XCTAssertNil(status.dischargeTarget)
            XCTAssertFalse(status.calibrationActive)
            XCTAssertEqual(status.error == nil, cancel)
            XCTAssertFalse(hardware.operations.contains("adapter:false"))
        }
    }
    func testControllerErrorAndConflictRestoreOnlyOwnedAdapter() throws {
        for conflict in [true, false] {
            let hardware = DischargeHardware()
            var failing = false
            var records: [Bool] = []
            let command = DischargeCommand(target: 80)
            let controller = HelperController(hardware: hardware, backend: "test", existingCommand: nil,
                readSettings: { if failing && !conflict { throw SaverError("settings unavailable") }; return Settings() },
                readBattery: { self.sample() }, checkConflict: { failing && conflict }, readCommand: { nil },
                persistAdapterRecovery: { records.append($0) })
            XCTAssertEqual(controller.tick(dischargeRequest: command).dischargeTarget, 80)
            hardware.operations = []; failing = true
            let status = controller.tick()
            XCTAssertNotNil(status.error)
            XCTAssertNil(status.dischargeTarget)
            XCTAssertEqual(hardware.operations.first, "adapter:true")
            XCTAssertEqual(records, [true, false])
            if conflict { XCTAssertEqual(hardware.operations, ["adapter:true"]) }
        }
    }
    func testRestartRecoversAdapterWithoutResumingDischarge() {
        let hardware = DischargeHardware()
        var records: [Bool] = []
        let controller = HelperController(hardware: hardware, backend: "test", existingCommand: nil,
            readSettings: { Settings() }, readBattery: { self.sample(85, external: false) },
            checkConflict: { false }, readCommand: { nil }, adapterRecoveryRequired: true,
            persistAdapterRecovery: { records.append($0) })
        let status = controller.tick()
        XCTAssertNil(status.dischargeTarget)
        XCTAssertEqual(hardware.operations, ["adapter:true", "charge:false"])
        XCTAssertEqual(records, [false])
    }
    func testStaleReadAndCutFailureAttemptRestoration() throws {
        for operation in ["charge:false", "adapter:false", "stale"] {
            let hardware = DischargeHardware(); let session = ProtectionSession(hardware: hardware)
            try session.startDischarge(sample: sample(), settings: Settings(), target: 80)
            if operation == "stale" {
                _ = try session.update(sample(), settings: Settings())
                hardware.operations = []
            } else { hardware.fail = operation }
            let reading = operation == "stale" ? sample(date: Date(timeIntervalSinceNow: -31)) : sample()
            XCTAssertThrowsError(try session.update(reading, settings: Settings()))
            XCTAssertFalse(session.discharge.active)
            XCTAssertTrue(hardware.operations.contains("adapter:true"))
        }
    }
    func testStatusMigrationDefaultsAndRoundtrip() throws {
        var status = HelperStatus(state: "test", error: nil, settings: Settings(), sample: nil,
                                  backend: "test", chargingAllowed: false)
        status.dischargeSupported = true; status.dischargeTarget = 80; status.adapterRecoveryRequired = true
        status.dischargeCommandID = UUID()
        let encoded = try JSONEncoder().encode(status)
        XCTAssertEqual(try JSONDecoder().decode(HelperStatus.self, from: encoded), status)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["dischargeSupported", "dischargeTarget", "dischargeCommandID", "adapterRecoveryRequired"] { json.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(HelperStatus.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(old.dischargeSupported)
        XCTAssertNil(old.dischargeTarget)
        XCTAssertNil(old.dischargeCommandID)
        XCTAssertFalse(old.adapterRecoveryRequired)
    }
    func testDischargeReleasesChargingSleepHold() throws {
        let hardware = ChargingSleepGuardTests.Hardware()
        let guardSubject = ChargingSleepGuard(hardware: hardware)
        var status = ChargingSleepGuardTests().status()
        try guardSubject.update(status: status)
        XCTAssertTrue(guardSubject.isHolding)
        status.dischargeTarget = 80
        try guardSubject.update(status: status)
        XCTAssertFalse(guardSubject.isHolding)
        XCTAssertEqual(hardware.writes, [true, false])
    }

    func testRejectedCommandResultSurvivesLaterHealthyTicks() {
        let hardware = DischargeHardware()
        let command = DischargeCommand(target: 81)
        let controller = HelperController(hardware: hardware, backend: "test", existingCommand: nil,
            readSettings: { Settings() }, readBattery: { self.sample() }, checkConflict: { false },
            readCommand: { nil })
        let rejected = controller.tick(dischargeRequest: command)
        XCTAssertNotNil(rejected.error)
        XCTAssertEqual(rejected.dischargeCommandID, command.id)
        let later = controller.tick()
        XCTAssertNil(later.error)
        XCTAssertEqual(later.dischargeCommandError, rejected.error)
        XCTAssertNil(later.dischargeTarget)
    }

}
