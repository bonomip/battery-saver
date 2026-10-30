import XCTest
@testable import BatteryCore

final class BatteryActivityTests: XCTestCase {
    func testLowBatteryBoundaryAndChargingPriority() {
        for activity in [BatteryActivity.onBattery, .pluggedIn] {
            XCTAssertEqual(activity.tone(percent: 15), activity == .pluggedIn ? .blue : .yellow)
            XCTAssertEqual(activity.tone(percent: 14), .red)
            XCTAssertEqual(activity.tone(percent: 0), .red)
        }
        XCTAssertEqual(BatteryActivity.onBattery.tone(percent: 16), .yellow)
        XCTAssertEqual(BatteryActivity.pluggedIn.tone(percent: 16), .blue)
        XCTAssertEqual(BatteryActivity.charging.tone(percent: 15), .green)
        XCTAssertEqual(BatteryActivity.charging.tone(percent: 0), .green)
    }
    func testColorBoundariesAndWeakAdapterWarning() {
        for percent in [45, 46, 100] {
            XCTAssertEqual(BatteryActivity.onBattery.tone(percent: percent), .neutral)
        }
        for percent in [15, 16, 44] {
            XCTAssertEqual(BatteryActivity.onBattery.tone(percent: percent), .yellow)
        }
        for percent in [0, 14, 15, 44, 45, 100] {
            XCTAssertEqual(BatteryActivity.charging.tone(percent: percent), .green)
            XCTAssertEqual(BatteryActivity.pluggedIn.tone(percent: percent), percent < 15 ? .red : .blue)
            XCTAssertEqual(BatteryActivity.pluggedInDraining.tone(percent: percent), percent < 15 ? .red : .yellow)
        }
    }

    func testUnavailableOrInvalidChargeNeverShowsLowOrChargingColor() {
        XCTAssertEqual(BatteryActivity.unavailable.tone(percent: 15), .gray)
        for percent in [nil, -1, 101] as [Int?] {
            XCTAssertEqual(BatteryActivity.charging.tone(percent: percent), .gray)
        }
    }
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
