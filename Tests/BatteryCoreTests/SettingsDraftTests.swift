import XCTest
@testable import BatteryCore

final class SettingsDraftTests: XCTestCase {
    func status(_ settings: Settings, date: Date = Date(), error: String? = nil) -> HelperStatus {
        HelperStatus(date: date, state: "Paused", error: error, settings: settings, sample: nil, backend: "Mock", chargingAllowed: false)
    }

    func testAcknowledgementPreservesEditsMadeDuringAuthorization() throws {
        var draft = SettingsDraft(settings: Settings())
        let submitted = try draft.beginApply()
        draft.edit(\.upper, to: 90)
        let now = Date()
        draft.authorizationFinished(succeeded: true, now: now)
        XCTAssertNil(draft.refresh(status: status(submitted, date: now)))
        XCTAssertEqual(draft.settings.upper, 90)
        XCTAssertTrue(draft.edited)
        XCTAssertNil(draft.pendingSettings)
    }

    func testAcknowledgementAcceptsUnchangedDraftAndThenFollowsExternalSettings() throws {
        var draft = SettingsDraft()
        draft.edit(\.enabled, to: true)
        let submitted = try draft.beginApply()
        let now = Date()
        draft.authorizationFinished(succeeded: true, now: now)
        XCTAssertNil(draft.refresh(status: status(submitted, date: now)))
        XCTAssertFalse(draft.edited)
        XCTAssertNil(draft.pendingSettings)
        let external = Settings(lower: 60, upper: 70)
        XCTAssertNil(draft.refresh(status: status(external)))
        XCTAssertEqual(draft.settings, external)
    }

    func testOldOrFailedStatusCannotAcknowledgeApply() throws {
        var draft = SettingsDraft(settings: Settings())
        let submitted = try draft.beginApply()
        let now = Date()
        draft.authorizationFinished(succeeded: true, now: now)
        for observation in [status(submitted, date: now.addingTimeInterval(-1)),
                            status(submitted, date: now, error: "Hardware failure"),
                            status(submitted, date: now.addingTimeInterval(-60))] {
            XCTAssertNil(draft.refresh(status: observation, now: now))
            XCTAssertNotNil(draft.pendingSettings)
        }
    }

    func testFailedAuthorizationPreservesDraftAndCanBeRetried() throws {
        var draft = SettingsDraft()
        draft.edit(\.upper, to: 90)
        _ = try draft.beginApply()
        draft.authorizationFinished(succeeded: false)
        XCTAssertNil(draft.pendingSettings)
        XCTAssertTrue(draft.edited)
        XCTAssertEqual(try draft.beginApply().upper, 90)
    }

    func testCancelledAuthorizationRestoresAppliedSettings() throws {
        let applied = Settings(lower: 75, upper: 80)
        var draft = SettingsDraft(settings: applied)
        draft.edit(\.upper, to: 85)
        XCTAssertEqual(try draft.beginApply().upper, 85)

        draft.authorizationFinished(succeeded: false, cancelled: true)

        XCTAssertEqual(draft.settings, applied)
        XCTAssertFalse(draft.edited)
        XCTAssertNil(draft.pendingSettings)
        XCTAssertNil(draft.refresh(status: nil, now: Date().addingTimeInterval(300)))
        XCTAssertEqual(draft.settings, applied)
    }

    func testCancellationRestoresLatestAppliedSettingsReceivedWhileEdited() throws {
        var draft = SettingsDraft(settings: Settings(lower: 70, upper: 80))
        draft.edit(\.upper, to: 85)
        let latest = Settings(lower: 75, upper: 80)
        XCTAssertNil(draft.refresh(status: status(latest)))
        XCTAssertEqual(draft.settings.upper, 85)
        XCTAssertEqual(draft.appliedSettings, latest)
        XCTAssertTrue(draft.edited)
        _ = try draft.beginApply()

        draft.authorizationFinished(succeeded: false, cancelled: true)

        XCTAssertEqual(draft.settings, latest)
        XCTAssertFalse(draft.edited)
        XCTAssertNil(draft.pendingSettings)
    }

    func testCancellationDiscardsEditsAndUsesLatestSettingsReceivedDuringAuthorization() throws {
        var draft = SettingsDraft(settings: Settings(lower: 70, upper: 80))
        draft.edit(\.upper, to: 85)
        _ = try draft.beginApply()
        draft.edit(\.upper, to: 90)
        draft.edit(\.enabled, to: false)
        let latest = Settings(lower: 75, upper: 80)
        XCTAssertNil(draft.refresh(status: status(latest)))
        XCTAssertEqual(draft.settings.upper, 90)

        draft.authorizationFinished(succeeded: false, cancelled: true)

        XCTAssertEqual(draft.settings, latest)
        XCTAssertFalse(draft.edited)
        XCTAssertNil(draft.pendingSettings)
    }

    func testTimeoutStartsAfterAuthorizationAndPreservesNewerDraft() throws {
        var draft = SettingsDraft(settings: Settings())
        _ = try draft.beginApply()
        let now = Date()
        XCTAssertNil(draft.refresh(status: nil, now: now.addingTimeInterval(300)))
        XCTAssertNotNil(draft.pendingSettings)
        draft.authorizationFinished(succeeded: true, now: now)
        draft.edit(\.upper, to: 90)
        XCTAssertNotNil(draft.refresh(status: nil, now: now.addingTimeInterval(20)))
        XCTAssertNil(draft.pendingSettings)
        XCTAssertTrue(draft.edited)
        XCTAssertEqual(try draft.beginApply().upper, 90)
    }

    func testUnavailableHelperClearsPendingAndProtectionToggle() throws {
        var draft = SettingsDraft(settings: Settings())
        _ = try draft.beginApply()
        draft.helperUnavailable()
        XCTAssertFalse(draft.settings.enabled)
        XCTAssertNil(draft.pendingSettings)
    }
}
