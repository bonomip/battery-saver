import Foundation

public protocol SleepSetting {
    func isSleepDisabled() throws -> Bool
    func setSleepDisabled(_ disabled: Bool) throws
}

/// Owns only sleep inhibition acquired by this helper. The durable marker is
/// written before acquisition and removed only after restoration is verified.
public final class ChargingSleepGuard {
    public private(set) var isHolding = false
    private let hardware: SleepSetting
    private let persistRecovery: (Bool) throws -> Void
    private let uptime: () -> TimeInterval
    private var started: TimeInterval?
    private var progressed: TimeInterval?
    private var lastTime: TimeInterval?
    private var highestPercent = -1
    private var blocked: String?

    public init(hardware: SleepSetting, recoveryRequired: Bool = false,
                persistRecovery: @escaping (Bool) throws -> Void = { _ in },
                uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.hardware = hardware
        self.persistRecovery = persistRecovery
        self.uptime = uptime
        isHolding = recoveryRequired
    }

    public func recover() throws { try release() }

    public func release() throws {
        guard isHolding else { return }
        if try hardware.isSleepDisabled() {
            try hardware.setSleepDisabled(false)
        }
        guard try !hardware.isSleepDisabled() else {
            throw SaverError("Sleep restoration could not be verified.")
        }
        try persistRecovery(false)
        isHolding = false
        started = nil
        progressed = nil
        lastTime = nil
        highestPercent = -1
    }

    public func update(status: HelperStatus) throws {
        let eligible: Bool
        if let sample = status.sample {
            eligible = status.settings.enabled && status.settings.keepAwakeUntilLimit && status.running
                && status.error == nil && status.dischargeTarget == nil && !status.calibrationActive && status.chargingAllowed == true
                && sample.externalPower && (0...100).contains(sample.percent)
                && sample.percent < status.settings.upper && sample.temperature.isFinite
                && sample.temperature < status.settings.heatPause
                && (-5...30).contains(Date().timeIntervalSince(sample.date))
                && (-5...30).contains(Date().timeIntervalSince(status.date))
        } else { eligible = false }
        guard eligible else {
            try release()
            blocked = nil
            started = nil
            progressed = nil
            lastTime = nil
            highestPercent = -1
            return
        }
        if let blocked {
            try release()
            throw SaverError(blocked)
        }
        let now = uptime()
        guard now.isFinite, now >= 0, lastTime.map({ now >= $0 }) ?? true else {
            try block("Charging sleep protection stopped because the monotonic clock moved backwards.")
            return
        }
        lastTime = now
        if isHolding {
            guard try hardware.isSleepDisabled() else {
                try block("Charging sleep protection was cleared by another controller; waiting for a new charging cycle.")
                return
            }
            if let started, now - started >= 8 * 60 * 60 {
                try block("Charging sleep protection reached its eight-hour limit.")
                return
            }
            if let sample = status.sample, sample.percent > highestPercent {
                highestPercent = sample.percent
                progressed = now
            }
            if let progressed, now - progressed >= 30 * 60 {
                try block("Charging sleep protection stopped after 30 minutes without battery progress.")
            }
            return
        }
        // An existing global setting belongs to someone else.
        guard try !hardware.isSleepDisabled() else { return }
        do { try persistRecovery(true) }
        catch {
            blocked = "Cannot save sleep recovery state; waiting for a new charging cycle."
            throw error
        }
        isHolding = true
        started = now
        progressed = now
        highestPercent = status.sample!.percent
        do {
            try hardware.setSleepDisabled(true)
            guard try hardware.isSleepDisabled() else {
                throw SaverError("Charging sleep protection could not be verified.")
            }
        } catch {
            blocked = "Could not keep the Mac awake; waiting for a new charging cycle."
            throw error
        }
    }

    private func block(_ message: String) throws {
        blocked = message
        try release()
        throw SaverError(message)
    }
}
