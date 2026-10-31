import Foundation

/// Session ownership only. Settings and hardware commands still require administrator authorization.
@objc public protocol HelperSessionProtocol {
    func check(withReply reply: @escaping (Data?, String?) -> Void)
    func begin(withReply reply: @escaping (Data?, String?) -> Void)
    func end(withReply reply: @escaping (String?) -> Void)
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
