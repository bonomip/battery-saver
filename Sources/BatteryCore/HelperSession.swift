import Foundation

/// An active console-user session can control bounded discharge. Settings remain root-only.
@objc public protocol HelperSessionProtocol {
    func check(withReply reply: @escaping (Data?, String?) -> Void)
    func begin(withReply reply: @escaping (Data?, String?) -> Void)
    func end(withReply reply: @escaping (String?) -> Void)
    func heartbeat()
    func discharge(to target: NSNumber?, identifier: String, withReply reply: @escaping (String?) -> Void)
}

/// Monotonic leases expire if the UI hangs, not just when its process disconnects.
public struct HelperSessionLease {
    public static let renewalInterval: TimeInterval = 5
    public static let timeout: TimeInterval = 30
    private var renewedAt: TimeInterval
    public init(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) { renewedAt = uptime }
    public mutating func renew(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) { renewedAt = uptime }
    public func expired(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        !uptime.isFinite || !renewedAt.isFinite || uptime < renewedAt || uptime - renewedAt >= Self.timeout
    }
}

public enum HelperSessionService {
    public static let name = AppIdentity.session
    public static func interface() -> NSXPCInterface {
        NSXPCInterface(with: HelperSessionProtocol.self)
    }
    public static func connection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: name, options: .privileged)
        connection.remoteObjectInterface = interface()
        return connection
    }
}
