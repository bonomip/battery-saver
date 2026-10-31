import Foundation
import BatteryCore
import Darwin

/// launchd starts this service on connection. Only a console-user lease enables policy.
final class AppSessionService: NSObject, NSXPCListenerDelegate {
    private let listener = NSXPCListener(machServiceName: HelperSessionService.name)
    private var clients: [UUID: SessionEndpoint] = [:]
    private var daemon: Daemon?
    private var shuttingDown = false
    private var idleGeneration = UUID()
    private var leaseTimer: Timer?
    private var dischargeOwner: UUID?

    func run() throws {
        try Daemon.recoverInterruptedOperations()
        listener.delegate = self
        listener.resume()
        leaseTimer = Timer.scheduledTimer(withTimeInterval: HelperSessionLease.renewalInterval, repeats: true) { [weak self] _ in
            self?.expireLeases()
        }
        scheduleIdleExit()
        RunLoop.main.run()
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        var console = stat()
        guard stat("/dev/console", &console) == 0,
              connection.effectiveUserIdentifier == 0 || connection.effectiveUserIdentifier == console.st_uid else { return false }
        let endpoint = SessionEndpoint(service: self)
        endpoint.connection = connection
        connection.exportedInterface = HelperSessionService.interface()
        connection.exportedObject = endpoint
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                endpoint.invalidated = true
                self?.disconnected(endpoint.id)
            }
        }
        connection.interruptionHandler = { connection.invalidate() }
        connection.resume()
        return true
    }
    fileprivate func begin(_ client: SessionEndpoint, reply: @escaping (Data?, String?) -> Void) {
        guard !shuttingDown, !client.invalidated else { reply(nil, "Helper is stopping. Retry shortly."); return }
        do {
            if daemon == nil {
                let instance = try Daemon()
                daemon = instance
                try instance.start()
            }
            clients[client.id] = client
            client.lease.renew()
            idleGeneration = UUID()
            reply(try JSONEncoder().encode(HelperVersion.current), nil)
        } catch {
            reply(nil, error.localizedDescription)
            stop()
        }
    }
    func end(_ id: UUID, reply: @escaping (String?) -> Void) {
        reply(release(id))
    }
    fileprivate func heartbeat(_ client: SessionEndpoint) {
        guard !client.invalidated, clients[client.id] === client else { return }
        client.lease.renew()
    }
    fileprivate func discharge(_ client: SessionEndpoint, target: NSNumber?, identifier: String, reply: @escaping (String?) -> Void) {
        guard !shuttingDown, !client.invalidated, clients[client.id] === client, let daemon = daemon,
              let id = UUID(uuidString: identifier) else { reply("An active app session is required."); return }
        if let target = target {
            guard target.doubleValue.isFinite, (21...100).contains(target.intValue),
                  target == NSNumber(value: target.intValue) else { reply("Invalid discharge target."); return }
        }
        client.lease.renew()
        let error = daemon.discharge(to: target?.intValue, id: id)
        if error == nil { dischargeOwner = target == nil ? nil : client.id }
        reply(error)
    }
    func check(reply: @escaping (Data?, String?) -> Void) {
        guard !shuttingDown else { reply(nil, "Helper is stopping."); return }
        do {
            // Recover a previous crash without applying saved charging policy.
            if daemon == nil {
                let status = try Daemon().stop()
                if let error = status.error { throw SaverError(error) }
            }
            reply(try JSONEncoder().encode(HelperVersion.current), nil)
        } catch { reply(nil, error.localizedDescription) }
    }
    private func disconnected(_ id: UUID) {
        _ = release(id)
    }
    private func release(_ id: UUID) -> String? {
        guard clients.removeValue(forKey: id) != nil else { return nil }
        if clients.isEmpty { return stop() }
        guard dischargeOwner == id else { return nil }
        dischargeOwner = nil
        return daemon?.discharge(to: nil, id: UUID())
    }
    private func expireLeases() {
        for client in Array(clients.values) where client.lease.expired() {
            client.invalidated = true
            client.connection?.invalidate()
            _ = release(client.id)
        }
    }
    @discardableResult private func stop() -> String? {
        guard !shuttingDown else { return nil }
        shuttingDown = true
        leaseTimer?.invalidate()
        let failure = daemon?.stop().error
        // Give XPC time to deliver the restoration acknowledgement before process exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(failure == nil ? 0 : 1) }
        return failure
    }
    private func scheduleIdleExit() {
        let generation = idleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, self.idleGeneration == generation, self.clients.isEmpty else { return }
            self.stop()
        }
    }
}

fileprivate final class SessionEndpoint: NSObject, HelperSessionProtocol {
    let id = UUID()
    var invalidated = false
    var lease = HelperSessionLease()
    weak var connection: NSXPCConnection?
    private weak var service: AppSessionService?
    init(service: AppSessionService) { self.service = service }
    func check(withReply reply: @escaping (Data?, String?) -> Void) {
        DispatchQueue.main.async { [self] in service?.check(reply: reply) }
    }
    func begin(withReply reply: @escaping (Data?, String?) -> Void) {
        DispatchQueue.main.async { [self] in service?.begin(self, reply: reply) }
    }
    func end(withReply reply: @escaping (String?) -> Void) {
        DispatchQueue.main.async { [self] in service?.end(id, reply: reply) }
    }
    func heartbeat() {
        DispatchQueue.main.async { [self] in service?.heartbeat(self) }
    }
    func discharge(to target: NSNumber?, identifier: String, withReply reply: @escaping (String?) -> Void) {
        DispatchQueue.main.async { [self] in service?.discharge(self, target: target, identifier: identifier, reply: reply) }
    }
}

/// Used by the root installer/updater to verify Mach-service activation without enabling policy.
func checkSessionService() throws {
    let connection = HelperSessionService.connection()
    var finished = false
    var failure: String?
    connection.resume()
    defer { connection.invalidate() }
    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        DispatchQueue.main.async { failure = error.localizedDescription; finished = true }
    } as? HelperSessionProtocol
    proxy?.check { data, error in
        DispatchQueue.main.async {
            if let error = error { failure = error }
            else if data.flatMap({ try? JSONDecoder().decode(HelperVersion.self, from: $0) }) != .current {
                failure = "The activated helper version does not match the installed helper."
            }
            finished = true
        }
    }
    let deadline = Date().addingTimeInterval(8)
    while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    guard finished, failure == nil else { throw SaverError(failure ?? "Helper activation timed out.") }
    print("On-demand helper activation verified; settings were not changed.")
}
