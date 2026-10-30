import XCTest
@testable import BatteryCore

final class PMSetSleepSettingTests: XCTestCase {
    func testRealReadOnlyCommandRunnerCompletesWithoutPowerMutation() throws {
        let text = try PMSetSleepSetting.run("/usr/bin/pmset", ["-g"], 2)
        _ = try PMSetSleepSetting.parse(text)
    }
    func testRealRunnerTerminatesItsOwnTimedOutChild() {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try PMSetSleepSetting.run("/bin/sleep", ["3"], 0.05))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }
    func testWriteWaitsForDelayedRegistryConfirmationInBothDirections() throws {
        for target in [true, false] {
            var reads = 0
            var writes = 0
            let setting = PMSetSleepSetting(runner: { _, _, _ in writes += 1; return "" }, effectiveUserID: { 0 }, readSetting: {
                reads += 1
                return reads < 2 ? !target : target
            })
            try setting.setSleepDisabled(target)
            XCTAssertEqual(writes, 1)
            XCTAssertEqual(reads, 2)
        }
    }
    func testUnconfirmedSettingFailsWithinBoundedDeadline() {
        let setting = PMSetSleepSetting(runner: { _, _, _ in "" }, effectiveUserID: { 0 }, readSetting: { false })
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try setting.setSleepDisabled(true))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }
    func testReadbackErrorPropagatesAfterWrite() {
        let setting = PMSetSleepSetting(runner: { _, _, _ in "" }, effectiveUserID: { 0 }, readSetting: { throw SaverError("Injected read failure") })
        XCTAssertThrowsError(try setting.setSleepDisabled(true))
    }
    func testParserAcceptsOnlyExactBooleanValuesWithWhitespace() throws {
        XCTAssertFalse(try PMSetSleepSetting.parse("System-wide power settings:\n SleepDisabled\t\t0\n"))
        XCTAssertTrue(try PMSetSleepSetting.parse("\tSleepDisabled  1  \n"))
    }

    func testParserRejectsMissingMalformedDuplicateAndUnknownValues() {
        for output in ["", "SleepDisabled", "SleepDisabled 2", "SleepDisabled -1", "SleepDisabled true",
                       "SleepDisabled 01", "SleepDisabled 0 extra", "SleepDisabled=0", "sleepdisabled 0",
                       "SleepDisabled 0\nSleepDisabled 0", "SleepDisabled 0\nSleepDisabled 1"] {
            XCTAssertThrowsError(try PMSetSleepSetting.parse(output), output)
        }
    }

    func testInjectedReadUsesFixedCommandAndDeadline() throws {
        var calls = 0
        let setting = PMSetSleepSetting(runner: { executable, arguments, timeout in
            calls += 1
            XCTAssertEqual(executable, "/usr/bin/pmset")
            XCTAssertEqual(arguments, ["-g"])
            XCTAssertEqual(timeout, 2)
            return "SleepDisabled 1"
        })
        XCTAssertTrue(try setting.isSleepDisabled())
        XCTAssertEqual(calls, 1)
    }

    func testSetterUsesOnlyFixedArgumentsForBothTransitions() throws {
        var calls: [[String]] = []
        let setting = PMSetSleepSetting(runner: { executable, arguments, timeout in
            XCTAssertEqual(executable, "/usr/bin/pmset")
            XCTAssertEqual(timeout, 2)
            calls.append(arguments)
            return ""
        }, effectiveUserID: { 0 })
        try setting.setSleepDisabled(true)
        try setting.setSleepDisabled(false)
        XCTAssertEqual(calls, [["-a", "disablesleep", "1"], ["-a", "disablesleep", "0"]])
    }

    func testNonrootSetterRejectsBeforeRunningCommand() {
        let setting = PMSetSleepSetting(runner: { _, _, _ in
            XCTFail("Nonroot setter must not launch pmset")
            return ""
        }, effectiveUserID: { 501 })
        XCTAssertThrowsError(try setting.setSleepDisabled(true))
        XCTAssertThrowsError(try setting.setSleepDisabled(false))
    }

    func testReadAndWritePropagateRunnerFailuresIncludingTimeout() {
        enum Failure: Error, Equatable { case commandFailed, timedOut }
        for failure in [Failure.commandFailed, .timedOut] {
            let setting = PMSetSleepSetting(runner: { _, _, _ in throw failure }, effectiveUserID: { 0 })
            XCTAssertThrowsError(try setting.isSleepDisabled()) { XCTAssertEqual($0 as? Failure, failure) }
            XCTAssertThrowsError(try setting.setSleepDisabled(true)) { XCTAssertEqual($0 as? Failure, failure) }
        }
    }
}
