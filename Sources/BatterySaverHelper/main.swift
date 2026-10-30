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
    (try? Data(contentsOf: URL(fileURLWithPath: requestPath))).flatMap {
        try? JSONDecoder().decode(CalibrationCommand.self, from: $0)
    }
}

let dischargeRequestPath = Locations.directory + "/discharge-request.json"
func readDischargeCommand() -> DischargeCommand? {
    (try? Data(contentsOf: URL(fileURLWithPath: dischargeRequestPath))).flatMap { try? JSONDecoder().decode(DischargeCommand.self, from: $0) }
}

final class Daemon {
    let controller: HelperController
    let sleepGuard: ChargingSleepGuard
    var signals: [DispatchSourceSignal] = []
    var timer: Timer?
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
                                      persistAdapterRecovery: recoveryStore.write,
                                      existingDischarge: readDischargeCommand(), readDischarge: readDischargeCommand)
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
        catch { fputs("Status write failed: \(error.localizedDescription)\n", stderr) }
        return output
    }
    func power(_ sleeping: Bool) { publish(sleeping ? controller.sleep() : controller.wake()) }
    func run() throws {
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
                let stopped = publish(controller.stop())
                bs_power_stop(); exit(stopped.error == nil ? 0 : 1)
            }
            source.resume(); signals.append(source)
        }
        publish(controller.tick())
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [self] _ in publish(controller.tick()) }
        RunLoop.main.run()
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first ?? "--probe" {
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
        do { try Daemon().run() }
        catch {
            try? writeJSON(HelperStatus(state: "Helper could not start", error: error.localizedDescription,
                                       settings: Settings(enabled: false), sample: nil, backend: "Unavailable",
                                       chargingAllowed: nil, running: false), path: Locations.status)
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
    case "--discharge", "--cancel-discharge":
        try checkRootDirectory()
        let target: Int?
        if arguments[0] == "--discharge" {
            guard arguments.count == 3, let value = Int(arguments[1]), (21...100).contains(value),
                  try Locations.readSettings().enabled, try !conflicts() else { throw SaverError("Invalid discharge request.") }
            target = value
        } else {
            guard arguments.count == 2 else { throw SaverError("Invalid cancellation request.") }
            target = nil
        }
        guard let id = UUID(uuidString: arguments.last ?? "") else { throw SaverError("Missing discharge request identifier.") }
        try writeJSON(DischargeCommand(id: id, target: target), path: dischargeRequestPath)
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
