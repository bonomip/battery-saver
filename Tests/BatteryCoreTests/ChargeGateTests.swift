import XCTest
@testable import BatteryCore

private final class ScriptedSMC: SMCTransport {
    var values: [String: [UInt8]] = ["CH0B": [0], "CH0C": [0], "CH0I": [0]]
    var readCounts: [String: Int] = [:]
    var failedReads: [String: Set<Int>] = [:]
    var failedWrites: Set<String> = []
    var ignoredWrites: Set<String> = []
    var writes: [String] = []
    func read(_ key: String) throws -> [UInt8] {
        let count = (readCounts[key] ?? 0) + 1
        readCounts[key] = count
        if failedReads[key]?.contains(count) == true { throw SaverError("Injected read failure for \(key)") }
        guard let value = values[key] else { throw SaverError("Missing \(key)") }
        return value
    }
    func write(_ key: String, bytes: [UInt8]) throws {
        writes.append("\(key)=\(bytes)")
        if failedWrites.contains(key) { throw SaverError("Injected write failure for \(key)") }
        if !ignoredWrites.contains(key) { values[key] = bytes }
    }
}

final class ChargeGateTests: XCTestCase {
    func testPauseReadFailureNeverEnablesChargeAndStillAttemptsOtherGate() throws {
        let transport = ScriptedSMC()
        transport.values["CH0B"] = [2]
        let gate = try ChargeGate(transport: transport, writeAuthorized: { true })
        transport.failedReads["CH0B"] = [2]
        XCTAssertThrowsError(try gate.setAllowed(false))
        XCTAssertEqual(transport.values["CH0B"], [2])
        XCTAssertEqual(transport.values["CH0C"], [2])
        XCTAssertEqual(transport.writes, ["CH0C=[2]"])
    }

    func testPauseWriteFailureStillAttemptsOtherGateWithoutEnablingRollback() throws {
        let transport = ScriptedSMC()
        let gate = try ChargeGate(transport: transport, writeAuthorized: { true })
        transport.failedWrites = ["CH0B"]
        XCTAssertThrowsError(try gate.setAllowed(false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("write failure for CH0B"))
        }
        XCTAssertEqual(transport.values["CH0C"], [2])
        XCTAssertEqual(transport.writes, ["CH0B=[2]", "CH0C=[2]"])
    }

    func testPauseReadbackMismatchStillAttemptsOtherGateAndReportsMismatch() throws {
        let transport = ScriptedSMC()
        let gate = try ChargeGate(transport: transport, writeAuthorized: { true })
        transport.ignoredWrites = ["CH0B"]
        XCTAssertThrowsError(try gate.setAllowed(false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("readback failed for CH0B"))
        }
        XCTAssertEqual(transport.values["CH0B"], [0])
        XCTAssertEqual(transport.values["CH0C"], [2])
        XCTAssertEqual(transport.writes, ["CH0B=[2]", "CH0C=[2]"])
    }

    func testSecondGateReadbackFailureDoesNotUndoSuccessfulPause() throws {
        let transport = ScriptedSMC()
        let gate = try ChargeGate(transport: transport, writeAuthorized: { true })
        transport.failedReads["CH0C"] = [3]
        XCTAssertThrowsError(try gate.setAllowed(false))
        XCTAssertEqual(transport.values["CH0B"], [2])
        XCTAssertEqual(transport.values["CH0C"], [2])
        XCTAssertEqual(transport.writes, ["CH0B=[2]", "CH0C=[2]"])
    }

    func testBothGateErrorsAreReported() throws {
        let transport = ScriptedSMC()
        let gate = try ChargeGate(transport: transport, writeAuthorized: { true })
        transport.failedWrites = ["CH0B"]
        transport.failedReads["CH0C"] = [2]
        XCTAssertThrowsError(try gate.setAllowed(false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("write failure for CH0B"))
            XCTAssertTrue(error.localizedDescription.contains("read failure for CH0C"))
        }
    }

    func testRestoreStillAttemptsSecondGateAfterFirstWriteFailure() throws {
        let transport = ScriptedSMC()
        transport.values["CH0B"] = [2]; transport.values["CH0C"] = [2]
        let gate = try ChargeGate(transport: transport, writeAuthorized: { true })
        transport.failedWrites = ["CH0B"]
        XCTAssertThrowsError(try gate.setAllowed(true))
        XCTAssertEqual(transport.values["CH0C"], [0])
        XCTAssertEqual(transport.writes, ["CH0B=[0]", "CH0C=[0]"])
    }

    func testFailedAdapterProbeRejectsConstructionAndLaterRetryCanRestore() throws {
        let transport = ScriptedSMC()
        transport.values["CH0I"] = [1]
        transport.failedReads["CH0I"] = [1]
        XCTAssertThrowsError(try ChargeGate(transport: transport, writeAuthorized: { true }))
        XCTAssertTrue(transport.writes.isEmpty)
        let retry = try ChargeGate(transport: transport, writeAuthorized: { true })
        XCTAssertTrue(retry.adapterSupported())
        try retry.setAdapter(true)
        XCTAssertEqual(transport.values["CH0I"], [0])
        XCTAssertEqual(transport.writes, ["CH0I=[0]"])
    }

    func testAllRequiredGateValuesAreValidatedWithoutWrites() {
        for key in ["CH0B", "CH0C", "CH0I"] {
            let invalid: [[UInt8]] = [[], [0, 0], key == "CH0I" ? [2] : [1]]
            for value in invalid {
                let transport = ScriptedSMC()
                transport.values[key] = value
                XCTAssertThrowsError(try ChargeGate(transport: transport, writeAuthorized: { true }), "\(key)=\(value)")
                XCTAssertTrue(transport.writes.isEmpty)
            }
            let missing = ScriptedSMC()
            missing.values.removeValue(forKey: key)
            XCTAssertThrowsError(try ChargeGate(transport: missing, writeAuthorized: { true }))
            XCTAssertTrue(missing.writes.isEmpty)
        }
    }

    func testAdapterWriteFailureAndReadbackMismatchAreReported() throws {
        for failWrite in [true, false] {
            let transport = ScriptedSMC()
            let gate = try ChargeGate(transport: transport, writeAuthorized: { true })
            if failWrite { transport.failedWrites = ["CH0I"] }
            else { transport.ignoredWrites = ["CH0I"] }
            XCTAssertThrowsError(try gate.setAdapter(false)) { error in
                XCTAssertTrue(error.localizedDescription.contains(failWrite ? "write failure" : "readback failed"))
            }
            XCTAssertEqual(transport.writes, ["CH0I=[1]"])
        }
    }

    func testWriteAuthorizationRejectsBothControlsWithoutTransportWrites() throws {
        let transport = ScriptedSMC()
        let gate = try ChargeGate(transport: transport, writeAuthorized: { false })
        XCTAssertThrowsError(try gate.setAllowed(false))
        XCTAssertThrowsError(try gate.setAdapter(false))
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testMatchingGateValuesNeedNoWrites() throws {
        let transport = ScriptedSMC()
        transport.values["CH0B"] = [2]; transport.values["CH0C"] = [2]
        let gate = try ChargeGate(transport: transport, writeAuthorized: { true })
        try gate.setAllowed(false)
        try gate.setAdapter(true)
        XCTAssertTrue(transport.writes.isEmpty)
    }
}
