import Foundation
import BatteryCore
import SMCBridge
import Darwin

func checkRootDirectory() throws {
    guard geteuid() == 0 else { throw SaverError("Run this operation through administrator authorization.") }
    var metadata = stat()
    guard lstat(Locations.directory, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFDIR, metadata.st_uid == 0,
          metadata.st_mode & 0o022 == 0 else { throw SaverError("Helper directory must be a root-owned directory with no group or other write access.") }
}
func writeJSON<T: Encodable>(_ value: T, path: String) throws {
    try checkRootDirectory()
    let data = try JSONEncoder().encode(value)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    guard chmod(path, 0o644) == 0 else { throw SaverError("Cannot set file permissions.") }
}
func conflicts() throws -> Bool {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "comm="]
    let pipe = Pipe(); process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw SaverError("Cannot inspect running charging controllers; activation refused.") }
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
    return lines.contains { line in
        let name = String(line).lowercased()
        return name.contains("aldente") || name.hasSuffix("/batt") || name.hasSuffix("/smc") || name.hasSuffix("/battery")
    }
}
let requestPath = Locations.directory + "/calibration-request.json"
let recoveryPath = Locations.directory + "/adapter-recovery.json"
let sleepRecoveryPath = Locations.directory + "/sleep-recovery.json"

func readCalibrationCommand() -> CalibrationCommand? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: requestPath)) else { return nil }
    return try? JSONDecoder().decode(CalibrationCommand.self, from: data)
}

final class Daemon {
    let controller: HelperController
    let sleepGuard: ChargingSleepGuard
    var signals: [DispatchSourceSignal] = []
    var timer: Timer?
    static func recoverInterruptedOperations() throws {
        let adapter = try AdapterRecoveryStore(path: recoveryPath).read()
        let sleep = try AdapterRecoveryStore(path: sleepRecoveryPath).read()
        guard adapter || sleep else { return }
        let status = try Daemon().stop()
        if let error = status.error { throw SaverError(error) }
    }
    init() throws {
        let sleepStore = AdapterRecoveryStore(path: sleepRecoveryPath)
        sleepGuard = ChargingSleepGuard(hardware: PMSetSleepSetting(), recoveryRequired: try sleepStore.read(),
                                       persistRecovery: sleepStore.write)
        try sleepGuard.recover()
        let recoveryStore = AdapterRecoveryStore(path: recoveryPath)
        let needsRecovery = try recoveryStore.read()
        let gate = try ChargeGate()
        controller = HelperController(hardware: gate, backend: gate.backend,
                                      existingCommand: readCalibrationCommand(),
                                      readSettings: Locations.readSettings, readBattery: BatteryReader.read,
                                      checkConflict: conflicts, readCommand: readCalibrationCommand,
                                      adapterRecoveryRequired: needsRecovery,
                                      persistAdapterRecovery: recoveryStore.write)
    }
    @discardableResult func publish(_ status: HelperStatus) -> HelperStatus {
        var output = status
        output.sleepControlAvailable = true
        do { try sleepGuard.update(status: status) }
        catch {
            var message = error.localizedDescription
            do { try sleepGuard.release() }
            catch { message += " Sleep restoration also failed: \(error.localizedDescription)" }
            output.error = [status.error, message].compactMap { $0 }.joined(separator: "; ")
            output.sleepMessage = message
        }
        output.sleepHeld = sleepGuard.isHolding
        if output.sleepHeld && output.sleepMessage == nil {
            output.sleepMessage = "Keeping awake until \(status.settings.upper)%"
        }
        do { try writeJSON(output, path: Locations.status) }
        catch {
            let message = "Status write failed: \(error.localizedDescription)"
            output.error = [output.error, message].compactMap { $0 }.joined(separator: "; ")
            fputs("\(message)\n", stderr)
        }
        return output
    }
    @discardableResult private func publishSafely(_ status: HelperStatus) -> HelperStatus {
        let output = publish(status)
        guard output.error != nil, output.adapterRecoveryRequired else { return output }
        // A failed status/sleep operation must not leave an adapter cut running.
        // Try restoration now; unsuccessful exits let launchd retry durable recovery.
        var restored = stop()
        restored.error = [output.error, restored.error].compactMap { $0 }.joined(separator: "; ")
        _ = publish(restored)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(1) }
        return restored
    }
    @discardableResult func tick(dischargeRequest: DischargeCommand? = nil) -> HelperStatus {
        publishSafely(controller.tick(dischargeRequest: dischargeRequest))
    }
    func discharge(to target: Int?, id: UUID) -> String? {
        let status = tick(dischargeRequest: DischargeCommand(id: id, target: target))
        if let error = status.error ?? status.dischargeCommandError { return error }
        guard status.dischargeCommandID == id else { return "Discharge command was not acknowledged." }
        if target == nil && status.adapterRecoveryRequired { return "Adapter restoration is still pending." }
        return nil
    }
    func power(_ sleeping: Bool) { publishSafely(sleeping ? controller.sleep() : controller.wake()) }
    func stop() -> HelperStatus {
        timer?.invalidate()
        let stopped = publish(controller.stop())
        bs_power_stop()
        return stopped
    }
    func start() throws {
        guard bs_power_start({ sleeping, context in
            guard let context = context else { return }
            Unmanaged<Daemon>.fromOpaque(context).takeUnretainedValue().power(sleeping != 0)
        }, Unmanaged.passUnretained(self).toOpaque()) == 0 else {
            publish(controller.stop())
            throw SaverError("Cannot register sleep notifications; refusing unattended charging control.")
        }
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [self] in
                let stopped = stop()
                exit(stopped.error == nil ? 0 : 1)
            }
            source.resume(); signals.append(source)
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [self] _ in tick() }
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first ?? "--probe" {
    case "--version-json":
        guard arguments.count == 1 else { throw SaverError("Usage: --version-json") }
        print(String(decoding: try JSONEncoder().encode(HelperVersion.current), as: UTF8.self))
    case "--check-stopped":
        guard arguments.count == 1 else { throw SaverError("Usage: --check-stopped") }
        try checkRootDirectory()
        let lock = try ExclusiveFileLock(path: Locations.directory + "/daemon.lock")
        withExtendedLifetime(lock) { print("Helper control lock is released.") }
    case "--check-service":
        guard arguments.count == 1 else { throw SaverError("Usage: --check-service") }
        try checkRootDirectory()
        try checkSessionService()
    case "--migrate-settings":
        guard arguments.count == 2 else { throw SaverError("Usage: --migrate-settings path") }
        let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        FileHandle.standardOutput.write(try SettingsMigration.migrate(data))
    case "--probe":
        let sample = try BatteryReader.read()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(sample), as: UTF8.self))
        let gate = try ChargeGate()
        print("Read-only SMC gates: \(try gate.values()); calibration adapter supported: \(gate.adapterSupported())")
    case "--battery-json":
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(BatteryReader.read()), as: UTF8.self))
    case "--sleep-status":
        print("SleepDisabled: \(try PMSetSleepSetting().isSleepDisabled() ? 1 : 0)")
    case "--restore-sleep":
        try checkRootDirectory()
        let lock = try ExclusiveFileLock(path: Locations.directory + "/daemon.lock")
        defer { withExtendedLifetime(lock) {} }
        let store = AdapterRecoveryStore(path: sleepRecoveryPath)
        try ChargingSleepGuard(hardware: PMSetSleepSetting(), recoveryRequired: store.read(), persistRecovery: store.write).recover()
        print("Any saved Battery Saver sleep hold was restored. Charging settings were not changed.")
    case "--daemon":
        try checkRootDirectory()
        // Only the lock holder may open hardware or publish daemon status.
        // A second launch must never overwrite the live daemon's status.
        let lock = try ExclusiveFileLock(path: Locations.directory + "/daemon.lock")
        defer { withExtendedLifetime(lock) {} }
        do { try AppSessionService().run() }
        catch {
            var status = HelperStatus(state: "Helper recovery failed", error: error.localizedDescription,
                                      settings: (try? Locations.readSettings()) ?? Settings(enabled: false),
                                      sample: nil, backend: "Recovery", chargingAllowed: nil, running: false)
            status.adapterRecoveryRequired = (try? AdapterRecoveryStore(path: recoveryPath).read()) ?? true
            try? writeJSON(status, path: Locations.status)
            throw error
        }
    case "--configure":
        try checkRootDirectory()
        guard (arguments.count == 6 || arguments.count == 7), let enabled = Int(arguments[1]), [0, 1].contains(enabled),
              let lower = Int(arguments[2]), let upper = Int(arguments[3]), let pause = Double(arguments[4]), let resume = Double(arguments[5]) else {
            throw SaverError("Usage: --configure 0|1 lower upper pauseTemperature resumeTemperature [keepAwakeUntilLimit:0|1]")
        }
        let keepAwake: Bool
        if arguments.count == 7 {
            guard let value = Int(arguments[6]), [0, 1].contains(value) else { throw SaverError("Keep-awake setting must be 0 or 1.") }
            keepAwake = value == 1
        } else { keepAwake = (try? Locations.readSettings().keepAwakeUntilLimit) ?? true }
        let settings = Settings(enabled: enabled == 1, lower: lower, upper: upper, heatPause: pause, heatResume: resume, keepAwakeUntilLimit: keepAwake)
        try settings.validate()
        if settings.enabled { if try conflicts() { throw SaverError("AlDente or another controller is running. Stop it before activating Battery Saver.") } }
        try writeJSON(settings, path: Locations.settings)
        print("Settings saved. The helper applies them within five seconds.")
    case "--calibrate", "--cancel-calibration":
        try checkRootDirectory()
        if arguments[0] == "--calibrate" {
            guard try Locations.readSettings().enabled, try !conflicts() else { throw SaverError("Activate protection and stop other controllers first.") }
        }
        try writeJSON(CalibrationCommand(start: arguments[0] == "--calibrate"), path: requestPath)
    case "--restore":
        try checkRootDirectory()
        // Standalone restoration cannot race a running calibration tick.
        let lock = try ExclusiveFileLock(path: Locations.directory + "/daemon.lock")
        defer { withExtendedLifetime(lock) {} }
        let sleepStore = AdapterRecoveryStore(path: sleepRecoveryPath)
        try ChargingSleepGuard(hardware: PMSetSleepSetting(), recoveryRequired: sleepStore.read(),
                               persistRecovery: sleepStore.write).recover()
        guard try !conflicts() else { throw SaverError("Another charging controller is running. Stop it before restoring hardware gates.") }
        try writeJSON(Settings(enabled: false), path: Locations.settings)
        try writeJSON(CalibrationCommand(start: false), path: requestPath)
        let recoveryStore = AdapterRecoveryStore(path: recoveryPath)
        let needsRecovery = try recoveryStore.read()
        let gate = try ChargeGate()
        try ProtectionSession(hardware: gate, adapterRecoveryRequired: needsRecovery,
                              persistAdapterRecovery: recoveryStore.write).restore()
        print("Adapter and charging gates restored. macOS decides whether charging is needed.")
    default: throw SaverError("Unknown command. Use --probe for read-only diagnostics.")
    }
} catch {
    fputs("Battery Saver: \(error.localizedDescription)\n", stderr); exit(1)
}
