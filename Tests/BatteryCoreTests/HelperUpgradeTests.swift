import XCTest
@testable import BatteryCore

final class HelperUpgradeTests: XCTestCase {
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
        let compatible = HelperVersion(revision: 3, protocolVersion: 1, settingsSchema: 1)
        XCTAssertEqual(HelperUpgrade.assess(installed: true, version: compatible, runningVersion: compatible), .ready)
        for version in [HelperVersion(revision: 1, protocolVersion: 2, settingsSchema: 1),
                        HelperVersion(revision: 3, protocolVersion: 2, settingsSchema: 1),
                        HelperVersion(revision: 3, protocolVersion: 1, settingsSchema: 2),
                        HelperVersion(revision: -1, protocolVersion: 1, settingsSchema: 1)] {
            guard case .blocked = HelperUpgrade.assess(installed: true, version: version, runningVersion: version) else {
                XCTFail("Must block incompatible helper \(version)"); continue
            }
        }
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
