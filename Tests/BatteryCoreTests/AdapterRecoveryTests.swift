import XCTest
@testable import BatteryCore

private final class JournalHardware: ChargingHardware {
    var operations: [String] = []
    var adapterEnabled = true
    func adapterSupported() -> Bool { true }
    func setAdapter(_ enabled: Bool) throws { operations.append("adapter:\(enabled)"); adapterEnabled = enabled }
    func setAllowed(_ allowed: Bool) throws { operations.append("charge:\(allowed)") }
}
final class AdapterRecoveryTests: XCTestCase {
    func sample(_ percent: Int, ac: Bool = true) -> BatterySample {
        BatterySample(date: Date(), percent: percent, temperature: 25, externalPower: ac, charging: false, currentMA: 0, voltageMV: 12000, cycles: 1, healthPercent: 90)
    }
    func testIntentIsRecordedBeforeCutAndClearedOnlyAfterRestoration() throws {
        let hardware = JournalHardware()
        let session = ProtectionSession(hardware: hardware, persistAdapterRecovery: {
            hardware.operations.append("marker:\($0)")
            if !$0 { XCTAssertTrue(hardware.adapterEnabled) }
        })
        try session.startCalibration()
        _ = try session.update(sample(90), settings: Settings())
        XCTAssertEqual(hardware.operations, ["charge:false", "marker:true", "adapter:false"])
        session.cancelCalibration(); hardware.operations = []
        let result = try session.update(sample(95, ac: false), settings: Settings())
        XCTAssertFalse(result.allowCharging)
        XCTAssertEqual(hardware.operations, ["adapter:true", "marker:false", "charge:false"])
    }
    func testFailedIntentWriteNeverCutsAdapter() throws {
        let hardware = JournalHardware()
        let session = ProtectionSession(hardware: hardware, persistAdapterRecovery: { required in
            if required { throw SaverError("Disk failure") }
        })
        try session.startCalibration()
        XCTAssertThrowsError(try session.update(sample(50), settings: Settings()))
        XCTAssertFalse(hardware.operations.contains("adapter:false"))
        XCTAssertTrue(hardware.adapterEnabled)
    }
    func testFailedClearRetainsRecoveryIntentAndRetries() throws {
        let hardware = JournalHardware()
        var failClear = true
        let session = ProtectionSession(hardware: hardware, adapterRecoveryRequired: true, persistAdapterRecovery: { required in
            if !required && failClear { throw SaverError("Disk failure") }
        })
        XCTAssertThrowsError(try session.relinquish())
        XCTAssertTrue(session.adapterMayBeDisabled)
        XCTAssertTrue(hardware.adapterEnabled)
        failClear = false
        try session.relinquish()
        XCTAssertFalse(session.adapterMayBeDisabled)
        XCTAssertEqual(hardware.operations, ["adapter:true", "adapter:true"])
    }
}
