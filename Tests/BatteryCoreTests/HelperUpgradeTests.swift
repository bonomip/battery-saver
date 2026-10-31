import XCTest
@testable import BatteryCore

final class HelperUpgradeTests: XCTestCase {
    func testSessionStartupRejectsUnsupportedInstalledVersions() {
        let current = HelperVersion.current
        XCTAssertTrue(current.canStartAppSession)
        XCTAssertFalse(HelperVersion(revision: current.revision - 1, protocolVersion: current.protocolVersion, settingsSchema: current.settingsSchema).canStartAppSession)
        XCTAssertFalse(HelperVersion(revision: current.revision, protocolVersion: current.protocolVersion + 1, settingsSchema: current.settingsSchema).canStartAppSession)
        XCTAssertFalse(HelperVersion(revision: current.revision, protocolVersion: current.protocolVersion, settingsSchema: current.settingsSchema + 1).canStartAppSession)
    }
    func testRecentRuntimeIsDistinctFromHealthyStatus() {
        var status = HelperStatus(state: "Error", error: "Sensor unavailable", settings: Settings(), sample: nil,
                                  backend: "test", chargingAllowed: nil)
        XCTAssertTrue(status.isRecentRuntime)
        XCTAssertFalse(status.isCurrent)
        status.error = nil
        XCTAssertTrue(status.isCurrent)
        status.date = Date().addingTimeInterval(-60)
        XCTAssertFalse(status.isRecentRuntime)
        status.date = Date().addingTimeInterval(60)
        XCTAssertFalse(status.isRecentRuntime)
        status.date = Date(); status.running = false
        XCTAssertFalse(status.isRecentRuntime)
    }
    func testFreshInstallationAndNoUpdateNeeded() {
        XCTAssertEqual(HelperUpgrade.assess(installed: false, version: nil, runningVersion: nil), .missing)
        XCTAssertEqual(HelperUpgrade.assess(installed: true, version: .current, runningVersion: .current), .ready)
    }
    func testLegacyAndReplacedButStillRunningOldHelperRequireUpdate() {
        XCTAssertEqual(HelperUpgrade.assess(installed: true, version: nil, runningVersion: nil), .updateRequired)
        let old = HelperVersion(revision: 1, protocolVersion: 1, settingsSchema: 0)
        XCTAssertEqual(HelperUpgrade.assess(installed: true, version: old, runningVersion: old), .updateRequired)
        XCTAssertEqual(HelperUpgrade.assess(installed: true, version: .current, runningVersion: old), .updateRequired)
    }
    func testNewerCompatibleHelperIsKeptAndIncompatibleDowngradesAreBlocked() {
        let current = HelperVersion.current
        let compatible = HelperVersion(revision: current.revision + 1, protocolVersion: current.protocolVersion, settingsSchema: current.settingsSchema)
        XCTAssertEqual(HelperUpgrade.assess(installed: true, version: compatible, runningVersion: compatible), .ready)
        for version in [HelperVersion(revision: 1, protocolVersion: current.protocolVersion + 1, settingsSchema: 1),
                        HelperVersion(revision: current.revision, protocolVersion: current.protocolVersion + 1, settingsSchema: 1),
                        HelperVersion(revision: current.revision, protocolVersion: current.protocolVersion, settingsSchema: current.settingsSchema + 1),
                        HelperVersion(revision: -1, protocolVersion: 1, settingsSchema: 1)] {
            guard case .blocked = HelperUpgrade.assess(installed: true, version: version, runningVersion: version) else {
                XCTFail("Must block incompatible helper \(version)"); continue
            }
        }
    }
    func testStoppedOnDemandHelperNeedsSessionRatherThanReinstallation() {
        XCTAssertEqual(HelperUpgrade.assess(installed: true, version: .current, runningVersion: nil), .starting)
        XCTAssertEqual(HelperUpgrade.assess(installed: true, version: .current, runningVersion: .current), .ready)
    }
    func testAuthorizationCancellationCannotClaimSuccessfulUpgradeAndCanRetry() {
        var authorization = HelperUpdateAuthorization()
        XCTAssertTrue(authorization.begin())
        XCTAssertFalse(authorization.begin())
        XCTAssertFalse(authorization.finish(succeeded: true, cancelled: true))
        XCTAssertFalse(authorization.pending)
        XCTAssertEqual(HelperUpgrade.assess(installed: true, version: nil, runningVersion: nil), .updateRequired)
        XCTAssertTrue(authorization.begin())
        XCTAssertFalse(authorization.finish(succeeded: false, cancelled: false))
        XCTAssertTrue(authorization.begin())
        XCTAssertTrue(authorization.finish(succeeded: true, cancelled: false))
    }
    func testLegacyStatusDoesNotInventRunningVersion() throws {
        let settings = String(decoding: try JSONEncoder().encode(Settings()), as: UTF8.self)
        let data = Data("{\"date\":0,\"state\":\"Paused\",\"settings\":\(settings),\"backend\":\"test\",\"calibrationActive\":false,\"running\":true}".utf8)
        XCTAssertNil(try JSONDecoder().decode(HelperStatus.self, from: data).helperVersion)
        let status = HelperStatus(state: "Paused", error: nil, settings: Settings(), sample: nil, backend: "test", chargingAllowed: false)
        XCTAssertEqual(try JSONDecoder().decode(HelperStatus.self, from: JSONEncoder().encode(status)).helperVersion, .current)
    }
}
