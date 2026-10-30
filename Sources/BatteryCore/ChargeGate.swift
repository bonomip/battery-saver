import Foundation
import SMCBridge

internal protocol SMCTransport: AnyObject {
    func read(_ key: String) throws -> [UInt8]
    func write(_ key: String, bytes: [UInt8]) throws
}

private final class NativeSMCTransport: SMCTransport {
    private var connection: UInt32 = 0
    init() throws {
        let code = bs_smc_open(&connection)
        guard code == 0 else { throw SaverError("Cannot open AppleSMC (\(code)).") }
    }
    deinit { bs_smc_close(connection) }
    func read(_ key: String) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        var length: UInt32 = 32
        let code = key.withCString { bs_smc_read(connection, $0, &bytes, &length) }
        guard code == 0 else { throw SaverError("Cannot read \(key) (\(code)). This firmware may be unsupported.") }
        return Array(bytes.prefix(Int(length)))
    }
    func write(_ key: String, bytes: [UInt8]) throws {
        guard geteuid() == 0 else { throw SaverError("Charging writes require the administrator-installed helper.") }
        let code = key.withCString { name in
            bytes.withUnsafeBufferPointer { bs_smc_write(connection, name, $0.baseAddress, UInt32($0.count)) }
        }
        guard code == 0 else { throw SaverError("Cannot write \(key) (\(code)).") }
    }
}

public final class ChargeGate {
    private let transport: SMCTransport
    private let writeAuthorized: () -> Bool
    public let keys = ["CH0B", "CH0C"]
    public var backend: String { keys.joined(separator: " + ") }
    public convenience init() throws {
        try self.init(transport: NativeSMCTransport(), writeAuthorized: { geteuid() == 0 })
    }
    internal init(transport: SMCTransport, writeAuthorized: @escaping () -> Bool) throws {
        self.transport = transport
        self.writeAuthorized = writeAuthorized
        // This targeted legacy backend requires every gate to be readable. A
        // failed adapter probe must not suppress recovery after calibration.
        for key in keys {
            let value = try read(key)
            guard value.count == 1, value[0] == 0 || value[0] == 2 else {
                throw SaverError("Unsupported \(key) value; refusing hardware control.")
            }
        }
        let adapter = try read("CH0I")
        guard adapter.count == 1, adapter[0] == 0 || adapter[0] == 1 else {
            throw SaverError("Unsupported CH0I value; refusing hardware control.")
        }
    }
    public func read(_ key: String) throws -> [UInt8] { try transport.read(key) }
    public func values() throws -> [String: [UInt8]] {
        var output: [String: [UInt8]] = [:]
        for key in keys { output[key] = try read(key) }
        return output
    }
    public func adapterSupported() -> Bool { true }
    public func setAdapter(_ enabled: Bool) throws {
        guard writeAuthorized() else { throw SaverError("Administrator access required.") }
        let value: [UInt8] = [enabled ? 0 : 1]
        if try read("CH0I") == value { return }
        try transport.write("CH0I", bytes: value)
        guard try read("CH0I") == value else { throw SaverError("Adapter readback failed for CH0I.") }
    }
    public func setAllowed(_ allowed: Bool) throws {
        guard writeAuthorized() else { throw SaverError("Charging writes require the administrator-installed helper.") }
        let target: [UInt8] = [allowed ? 0 : 2]
        var failures: [String] = []
        // Attempt each requested gate independently. Enabling charging after a
        // failed pause would reverse the policy, including heat/sleep protection.
        for key in keys {
            do {
                if try read(key) == target { continue }
                try transport.write(key, bytes: target)
                guard try read(key) == target else { throw SaverError("Charge readback failed for \(key).") }
            } catch { failures.append("\(key): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { throw SaverError(failures.joined(separator: "; ")) }
    }
}
