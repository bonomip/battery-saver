import XCTest
@testable import BatteryCore

final class BatteryActivityTests: XCTestCase {
    private func sample(connected: Bool, charging: Bool) -> BatterySample {
        BatterySample(date: Date(), percent: 68, temperature: 26, externalPower: connected,
                      charging: charging, currentMA: nil, voltageMV: nil, cycles: 432, healthPercent: 86)
    }
    func testConnectedDoesNotMeanCharging() {
        let activity = BatteryActivity(sample: sample(connected: true, charging: false))
        XCTAssertEqual(activity.title, "Plugged in · not charging")
        XCTAssertFalse(activity.isCharging)
    }
    func testActualChargingIsGreenStateRegardlessOfProtectionPolicy() {
        let activity = BatteryActivity(sample: sample(connected: true, charging: true))
        XCTAssertEqual(activity.title, "Charging")
        XCTAssertTrue(activity.isCharging)
    }
    func testUnplugOverridesLaggingChargingFlag() {
        for charging in [false, true] {
            let activity = BatteryActivity(sample: sample(connected: false, charging: charging))
            XCTAssertEqual(activity.title, "On battery")
            XCTAssertFalse(activity.isCharging)
        }
    }
    func testReconnectSequenceShowsOnlyObservedState() {
        let samples = [sample(connected: false, charging: false), sample(connected: true, charging: false),
                       sample(connected: true, charging: true), sample(connected: false, charging: false)]
        XCTAssertEqual(samples.map { BatteryActivity(sample: $0).title },
                       ["On battery", "Plugged in · not charging", "Charging", "On battery"])
    }
    func testUnavailableDoesNotPretendToBeOnBatteryOrCharging() {
        let activity = BatteryActivity(sample: nil)
        XCTAssertEqual(activity.title, "Battery status unavailable")
        XCTAssertFalse(activity.isCharging)
    }
}
