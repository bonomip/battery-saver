import XCTest
@testable import BatteryCore

final class HelperSessionTests: XCTestCase {
    func testLeaseExpiresOnMissingHeartbeatAndClockFailure() {
        var lease = HelperSessionLease(uptime: 10)
        XCTAssertFalse(lease.expired(uptime: 39.999))
        XCTAssertTrue(lease.expired(uptime: 40))
        lease.renew(uptime: 35)
        XCTAssertFalse(lease.expired(uptime: 40))
        XCTAssertTrue(lease.expired(uptime: 65))
        XCTAssertTrue(lease.expired(uptime: 34))
        XCTAssertTrue(lease.expired(uptime: .nan))
    }

    func testDischargeAndCancelCrossRealXPCWithoutAuthorization() {
        let listener = NSXPCListener.anonymous()
        let endpoint = SessionWireEndpoint()
        listener.delegate = endpoint
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = HelperSessionService.interface()
        connection.resume()
        defer { connection.invalidate(); endpoint.connection?.invalidate(); listener.invalidate() }
        let completed = expectation(description: "Discharge and cancellation replies")
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            XCTFail(error.localizedDescription); completed.fulfill()
        } as? HelperSessionProtocol
        proxy?.discharge(to: NSNumber(value: 80), identifier: UUID().uuidString) { error in
            XCTAssertNil(error)
            proxy?.discharge(to: nil, identifier: UUID().uuidString) { error in
                XCTAssertNil(error); completed.fulfill()
            }
        }
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(endpoint.targets.count, 2)
        XCTAssertEqual(endpoint.targets.first ?? nil, 80)
        XCTAssertNil(endpoint.targets.last ?? nil)
    }
}

/// Only the transport is exercised here; hardware behavior has separate controller tests.
private final class SessionWireEndpoint: NSObject, NSXPCListenerDelegate, HelperSessionProtocol {
    var connection: NSXPCConnection?
    var targets: [Int?] = []
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        self.connection = connection
        connection.exportedInterface = HelperSessionService.interface()
        connection.exportedObject = self
        connection.resume()
        return true
    }
    func check(withReply reply: @escaping (Data?, String?) -> Void) { reply(nil, nil) }
    func begin(withReply reply: @escaping (Data?, String?) -> Void) { reply(nil, nil) }
    func end(withReply reply: @escaping (String?) -> Void) { reply(nil) }
    func heartbeat() {}
    func discharge(to target: NSNumber?, identifier: String, withReply reply: @escaping (String?) -> Void) {
        targets.append(target?.intValue); reply(nil)
    }
}
