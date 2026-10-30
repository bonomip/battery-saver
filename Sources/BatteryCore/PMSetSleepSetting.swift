import Foundation
import Darwin
import IOKit

/// Reads and changes pmset's global SleepDisabled setting using fixed arguments.
public final class PMSetSleepSetting: SleepSetting {
    public typealias Runner = (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> String
    private let runner: Runner
    private let effectiveUserID: () -> uid_t
    private let readSetting: (() throws -> Bool)?
    private let timeout: TimeInterval = 2

    public init() {
        runner = Self.run
        effectiveUserID = { geteuid() }
        readSetting = Self.readRegistry
    }

    /// Injection allows tests to verify commands and failures without changing power settings.
    public init(runner: @escaping Runner) {
        self.runner = runner
        effectiveUserID = { geteuid() }
        readSetting = nil
    }

    /// Tests can exercise the root-only command path with a fake runner and identity.
    internal init(runner: @escaping Runner, effectiveUserID: @escaping () -> uid_t) {
        self.runner = runner
        self.effectiveUserID = effectiveUserID
        readSetting = nil
    }

    internal init(runner: @escaping Runner, effectiveUserID: @escaping () -> uid_t,
                  readSetting: @escaping () throws -> Bool) {
        self.runner = runner
        self.effectiveUserID = effectiveUserID
        self.readSetting = readSetting
    }

    public func isSleepDisabled() throws -> Bool {
        if let readSetting = readSetting { return try readSetting() }
        return try Self.parse(runner("/usr/bin/pmset", ["-g"], timeout))
    }

    private static func readRegistry() throws -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { throw SaverError("The system sleep settings registry is unavailable.") }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let number = value as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() || CFGetTypeID(value) == CFNumberGetTypeID(),
              number == NSNumber(value: 0) || number == NSNumber(value: 1) else {
            throw SaverError("The registry did not report a valid SleepDisabled setting.")
        }
        return number.boolValue
    }

    public func setSleepDisabled(_ disabled: Bool) throws {
        guard effectiveUserID() == 0 else { throw SaverError("Administrator authorization is required to change system sleep.") }
        _ = try runner("/usr/bin/pmset", ["-a", "disablesleep", disabled ? "1" : "0"], timeout)
        if let readSetting = readSetting {
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while true {
                if try readSetting() == disabled { return }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw SaverError("The system sleep setting did not confirm the requested change.") }
                Thread.sleep(forTimeInterval: min(0.05, remaining))
            }
        }
    }

    public static func parse(_ output: String) throws -> Bool {
        let values = output.split(whereSeparator: \.isNewline).compactMap { line -> [Substring]? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.first == "SleepDisabled" ? fields : nil
        }
        guard values.count == 1, values[0].count == 2,
              values[0][1] == "0" || values[0][1] == "1" else {
            throw SaverError("pmset did not report exactly one valid SleepDisabled setting.")
        }
        return values[0][1] == "1"
    }

    internal static func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.2) == .timedOut {
                // Only the child launched above is terminated; no process lookup or shell is used.
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.2)
            }
            throw SaverError("pmset timed out while accessing the system sleep setting.")
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let detail = error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SaverError(detail.isEmpty ? "pmset failed with status \(process.terminationStatus)." : "pmset failed: \(detail)")
        }
        return text
    }
}
