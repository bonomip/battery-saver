import Foundation

/// Session ownership only. Settings and hardware commands still require administrator authorization.
@objc public protocol HelperSessionProtocol {
    func check(withReply reply: @escaping (Data?, String?) -> Void)
    func begin(withReply reply: @escaping (Data?, String?) -> Void)
    func end(withReply reply: @escaping (String?) -> Void)
}

public enum HelperSessionService {
    public static let name = "local.paolo.battery-saver.session"
}
