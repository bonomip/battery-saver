import Foundation
import BatteryCore

/// A connection is a lease, not a hardware command. Invalidating it releases ownership.
final class HelperAppSession {
    private var connection: NSXPCConnection?
    private var connected = false
    private var wanted = false
    private var generation = UUID()
    private var completion: ((String?) -> Void)?
    private var heartbeatTimer: Timer?
    private(set) var error: String?
    var onChange: (() -> Void)?

    func start(completion: @escaping (String?) -> Void) {
        wanted = true
        if connected { completion(nil); return }
        guard connection == nil else { return }
        self.completion = completion
        let id = UUID()
        generation = id
        let connection = HelperSessionService.connection()
        self.connection = connection
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.failed(id, "The helper connection closed.") }
        }
        connection.interruptionHandler = { connection.invalidate() }
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            DispatchQueue.main.async { self?.failed(id, error.localizedDescription) }
        } as? HelperSessionProtocol
        proxy?.begin { [weak self] data, error in
            DispatchQueue.main.async {
                guard let self = self, self.generation == id else { return }
                guard let data = data, let version = try? JSONDecoder().decode(HelperVersion.self, from: data),
                      version.canStartAppSession,
                      error == nil else {
                    self.failed(id, error ?? "The activated helper is incompatible."); return
                }
                self.connected = true
                self.error = nil
                self.startHeartbeat()
                let callback = self.completion; self.completion = nil
                callback?(nil); self.onChange?()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.generation == id, !self.connected else { return }
            self.failed(id, "Helper startup timed out.")
        }
    }
    private func failed(_ id: UUID, _ error: String) {
        guard generation == id else { return }
        generation = UUID()
        self.error = error
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        let old = connection; connection = nil; connected = false
        old?.invalidate()
        let callback = completion; completion = nil
        callback?(error); onChange?()
        if wanted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self, self.wanted, self.connection == nil else { return }
                self.start { _ in self.onChange?() }
            }
        }
    }
    func stop(completion: @escaping (String?) -> Void) {
        wanted = false
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        generation = UUID()
        guard let connection = connection else { completion(error); return }
        self.connection = nil; connected = false
        self.completion = nil
        var replied = false
        let finish: (String?) -> Void = { error in
            guard !replied else { return }; replied = true
            connection.invalidate()
            completion(error)
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async { finish(error.localizedDescription) }
        } as? HelperSessionProtocol
        proxy?.end { error in DispatchQueue.main.async { finish(error) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish("Helper shutdown was not confirmed.") }
    }
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: HelperSessionLease.renewalInterval, repeats: true) { [weak self] _ in
            guard let self = self, self.connected, let connection = self.connection else { return }
            let id = self.generation
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                DispatchQueue.main.async { self.failed(id, error.localizedDescription) }
            } as? HelperSessionProtocol
            proxy?.heartbeat()
        }
        heartbeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func discharge(to target: Int?, identifier: UUID, completion: @escaping (String?) -> Void) {
        guard connected, let connection = connection else { completion("The helper is reconnecting. Try again shortly."); return }
        let id = generation
        var finished = false
        let finish: (String?, Bool) -> Void = { [weak self] error, transportFailed in
            guard !finished else { return }; finished = true
            if transportFailed, let error = error { self?.failed(id, error) }
            completion(error)
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async { finish(error.localizedDescription, true) }
        } as? HelperSessionProtocol
        proxy?.discharge(to: target.map { NSNumber(value: $0) }, identifier: identifier.uuidString) { [weak self] error in
            DispatchQueue.main.async {
                finish(self?.generation == id ? error : "The helper session changed; discharge was cancelled.", false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish("Discharge command timed out; stopping the helper session.", true) }
    }
    /// Used after uninstall; there is no installed service left to acknowledge a stop.
    func invalidate() {
        wanted = false; connected = false; generation = UUID(); error = nil
        completion = nil
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        let old = connection; connection = nil
        old?.invalidate()
    }
    deinit { heartbeatTimer?.invalidate(); connection?.invalidate() }
}
