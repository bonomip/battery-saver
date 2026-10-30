import XCTest
@testable import BatteryCore

final class InboxTests: XCTestCase {
    func testCommandConsumedOnlyOnceAndNotReplayedAfterRestart() {
        let command = CalibrationCommand(start: true)
        var inbox = CalibrationInbox()
        XCTAssertEqual(inbox.consume(command), true)
        XCTAssertNil(inbox.consume(command))
        var restarted = CalibrationInbox(existing: command)
        XCTAssertNil(restarted.consume(command))
        XCTAssertEqual(restarted.consume(CalibrationCommand(start: true)), true)
    }
    func testExpiredOrFutureStartRejectedAndCancelAccepted() {
        let now = Date()
        var inbox = CalibrationInbox()
        XCTAssertEqual(inbox.consume(CalibrationCommand(start: true, date: now.addingTimeInterval(-31)), now: now), false)
        XCTAssertEqual(inbox.consume(CalibrationCommand(start: true, date: now.addingTimeInterval(60)), now: now), false)
        XCTAssertEqual(inbox.consume(CalibrationCommand(start: false, date: now.addingTimeInterval(-300)), now: now), false)
    }
}
