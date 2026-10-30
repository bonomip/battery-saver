import XCTest
@testable import BatteryCore

private final class LifecycleHardware: ChargingHardware {
    var operations: [String] = []
    func adapterSupported() -> Bool { true }
    func setAdapter(_ enabled: Bool) throws { operations.append("adapter:\(enabled)") }
    func setAllowed(_ allowed: Bool) throws { operations.append("charge:\(allowed)") }
}
private final class LifecycleEnvironment {
    var conflict = false
    var conflictFails = false
    var settingsFail = false
    var settings = Settings()
    var command: CalibrationCommand?
    var settingsReads = 0
    var adapterRecoveryRequired = false
    var percent = 50
    var temperature: Double = 25
    func readSettings() throws -> Settings {
        settingsReads += 1
        if settingsFail { throw SaverError("Invalid settings") }
        return settings
    }
    func checkConflict() throws -> Bool {
        if conflictFails { throw SaverError("Cannot inspect processes") }
        return conflict
    }
    func sample() -> BatterySample {
        BatterySample(date: Date(), percent: percent, temperature: temperature, externalPower: true, charging: true, currentMA: 1000, voltageMV: 12000, cycles: 1, healthPercent: 90)
    }
    func controller(_ hardware: LifecycleHardware) -> HelperController {
        HelperController(hardware: hardware, backend: "test", existingCommand: command,
                         readSettings: { try self.readSettings() }, readBattery: { self.sample() },
                         checkConflict: { try self.checkConflict() }, readCommand: { self.command },
                         adapterRecoveryRequired: adapterRecoveryRequired,
                         persistAdapterRecovery: { self.adapterRecoveryRequired = $0 })
    }
}

final class HelperControllerTests: XCTestCase {
    func testWakeResumesInterruptedChargeInsideTheSailingRange() {
        let env = LifecycleEnvironment(); let hardware = LifecycleHardware()
        env.percent = 75
        let controller = env.controller(hardware)
        XCTAssertEqual(controller.tick().chargingAllowed, true)
        env.percent = 77
        XCTAssertEqual(controller.tick().chargingAllowed, true)
        XCTAssertEqual(controller.sleep().chargingAllowed, false)
        XCTAssertEqual(controller.wake().chargingAllowed, true)
        XCTAssertEqual(hardware.operations.last, "charge:true")
    }
    func testWakeDoesNotTopUpAnAlreadyPausedBatteryInTheRange() {
        let env = LifecycleEnvironment(); let hardware = LifecycleHardware()
        env.percent = 80
        let controller = env.controller(hardware)
        XCTAssertEqual(controller.tick().chargingAllowed, false)
        env.percent = 77
        _ = controller.sleep()
        XCTAssertEqual(controller.wake().chargingAllowed, false)
    }
    func testWakeStillHonorsNewUpperLimitAndTemperature() {
        for hot in [false, true] {
            let env = LifecycleEnvironment(); let hardware = LifecycleHardware()
            let controller = env.controller(hardware)
            XCTAssertEqual(controller.tick().chargingAllowed, true)
            _ = controller.sleep()
            if hot { env.temperature = 39 }
            else { env.percent = 81 }
            XCTAssertEqual(controller.wake().chargingAllowed, false)
        }
    }
    func testConflictPreventsRecoveryEvenWhenSettingsAreCorrupt() {
        let env = LifecycleEnvironment(); let hardware = LifecycleHardware()
        env.conflict = true; env.settingsFail = true
        let status = env.controller(hardware).tick()
        XCTAssertNotNil(status.error)
        XCTAssertEqual(env.settingsReads, 0)
        XCTAssertEqual(hardware.operations, [])
    }
    func testUnknownOwnershipPreventsTickSleepAndStopWrites() {
        let env = LifecycleEnvironment(); let hardware = LifecycleHardware()
        let controller = env.controller(hardware)
        _ = controller.tick(); hardware.operations = []
        env.conflictFails = true
        XCTAssertNotNil(controller.tick().error)
        XCTAssertNotNil(controller.sleep().error)
        XCTAssertNotNil(controller.stop().error)
        XCTAssertEqual(hardware.operations, [])
    }
    func testSleepAndStopRecheckNewCompetitor() {
        let env = LifecycleEnvironment(); let hardware = LifecycleHardware()
        let controller = env.controller(hardware)
        _ = controller.tick(); hardware.operations = []
        env.conflict = true
        XCTAssertNotNil(controller.sleep().error)
        XCTAssertNotNil(controller.stop().error)
        XCTAssertEqual(hardware.operations, [])
    }
    func testCompetitorDuringCalibrationRestoresOnlyOurAdapter() {
        let env = LifecycleEnvironment(); let hardware = LifecycleHardware()
        let controller = env.controller(hardware)
        env.command = CalibrationCommand(start: true)
        XCTAssertTrue(controller.tick().calibrationActive)
        XCTAssertEqual(hardware.operations.suffix(2), ["charge:false", "adapter:false"])
        hardware.operations = []; env.conflict = true
        let status = controller.tick()
        XCTAssertFalse(status.calibrationActive)
        XCTAssertNotNil(status.error)
        XCTAssertEqual(hardware.operations, ["adapter:true"])
    }
    func testDisabledHelperRestoresOnceAndThenLeavesGatesAlone() {
        let env = LifecycleEnvironment(); let hardware = LifecycleHardware()
        env.settings.enabled = false
        let controller = env.controller(hardware)
        XCTAssertNil(controller.tick().error)
        XCTAssertEqual(hardware.operations, ["adapter:true", "charge:true"])
        hardware.operations = []
        XCTAssertNil(controller.tick().error)
        XCTAssertEqual(hardware.operations, [])
    }
    func testDisablingActivePolicyRestoresAndStopsRepeatingWrites() {
        let env = LifecycleEnvironment(); let hardware = LifecycleHardware()
        let controller = env.controller(hardware)
        _ = controller.tick(); hardware.operations = []
        env.settings.enabled = false
        _ = controller.tick()
        XCTAssertEqual(hardware.operations, ["adapter:true", "charge:true"])
        hardware.operations = []
        _ = controller.tick()
        XCTAssertEqual(hardware.operations, [])
    }
    func testStoppedHelperImmediatelyLosesCurrentStatus() {
        let env = LifecycleEnvironment(); let hardware = LifecycleHardware()
        let controller = env.controller(hardware)
        _ = controller.tick()
        let status = controller.stop()
        XCTAssertFalse(status.running)
        XCTAssertFalse(status.isCurrent)
        XCTAssertFalse(controller.tick().running)
    }
    func testSleepUsesLatestDisabledSettings() {
        let env = LifecycleEnvironment(); let hardware = LifecycleHardware()
        let controller = env.controller(hardware)
        _ = controller.tick(); hardware.operations = []
        env.settings.enabled = false
        let status = controller.sleep()
        XCTAssertNil(status.error)
        XCTAssertEqual(hardware.operations, ["adapter:true", "charge:true"])
    }
    func testRestartDoesNotReplayExistingCalibrationCommand() {
        let env = LifecycleEnvironment(); let hardware = LifecycleHardware()
        env.command = CalibrationCommand(start: true)
        let status = env.controller(hardware).tick()
        XCTAssertFalse(status.calibrationActive)
        XCTAssertFalse(hardware.operations.contains("adapter:false"))
    }
    func testRestartRestoresRecordedAdapterCutEvenWhenOwnershipCannotBeAcquired() {
        for unknown in [false, true] {
            let env = LifecycleEnvironment(); let hardware = LifecycleHardware()
            let first = env.controller(hardware)
            env.command = CalibrationCommand(start: true)
            XCTAssertTrue(first.tick().calibrationActive)
            XCTAssertTrue(env.adapterRecoveryRequired)
            // Simulate process loss: only the recorded recovery intent survives.
            env.conflict = !unknown; env.conflictFails = unknown
            let restarted = env.controller(hardware)
            hardware.operations = []
            XCTAssertNotNil(restarted.tick().error)
            XCTAssertEqual(hardware.operations, ["adapter:true"])
            XCTAssertFalse(env.adapterRecoveryRequired)
        }
    }
}
