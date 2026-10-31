import XCTest
import IOKit.ps
@testable import BatteryCore

final class BatteryReaderTests: XCTestCase {
    private func source(charging: Any = false, power: String = kIOPSACPowerValue,
                        type: String = kIOPSInternalBatteryType) -> [String: Any] {
        [kIOPSTypeKey: type, kIOPSPowerSourceStateKey: power, kIOPSIsChargingKey: charging,
         kIOPSTimeToFullChargeKey: 30, kIOPSTimeToEmptyKey: 60]
    }
    func testPublicChargingStatusOverridesLaggingSensorInBothDirections() {
        let paused = BatteryReader.powerSourceState(rawCharging: true, externalPower: true, descriptions: [source()])
        XCTAssertFalse(paused.charging)
        XCTAssertEqual(paused.minutesToFull, 30)
        let charging = BatteryReader.powerSourceState(rawCharging: false, externalPower: true, descriptions: [source(charging: true)])
        XCTAssertTrue(charging.charging)
    }
    func testMismatchedPowerSourceOrInvalidFlagCannotOverrideSensor() {
        for description in [source(power: kIOPSBatteryPowerValue), source(type: "UPS"), source(charging: -1), source(charging: "false")] {
            let state = BatteryReader.powerSourceState(rawCharging: true, externalPower: true, descriptions: [description])
            XCTAssertTrue(state.charging)
            XCTAssertNil(state.minutesToFull)
        }
        let missing = BatteryReader.powerSourceState(rawCharging: false, externalPower: true, descriptions: [])
        XCTAssertFalse(missing.charging)
        XCTAssertNil(missing.minutesToEmpty)
    }
}
