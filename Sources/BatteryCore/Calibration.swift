import Foundation

public enum CalibrationPhase: String, Codable { case idle, discharging, charging, holding, completed, cancelled }
public struct CalibrationAction {
    public let allowCharging: Bool
    public let useAdapter: Bool
    public let reason: String
}
public struct Calibration: Codable {
    public private(set) var phase: CalibrationPhase = .idle
    public private(set) var holdStarted: Date?
    public private(set) var started: Date?
    private var startedUptime: TimeInterval?
    private var holdStartedUptime: TimeInterval?
    public init() {}
    public mutating func start(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        phase = .discharging; started = now; startedUptime = uptime
        holdStarted = nil; holdStartedUptime = nil
    }
    public mutating func cancel() { phase = .cancelled; holdStarted = nil; holdStartedUptime = nil }
    public var active: Bool { [.discharging, .charging, .holding].contains(phase) }
    public mutating func step(_ sample: BatterySample, settings: Settings, now: Date = Date(),
                              uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> CalibrationAction? {
        guard active else { return nil }
        try settings.validate()
        guard let startedUptime = startedUptime, uptime.isFinite, (0...86400).contains(uptime - startedUptime) else {
            cancel(); throw SaverError("Calibration exceeded 24 hours or its elapsed-time clock reset; normal policy restored.")
        }
        // Our discharge action deliberately removes adapter input. Once charging
        // begins, losing external power is an unexpected disconnect and cancels.
        guard sample.externalPower || phase == .discharging else {
            cancel(); throw SaverError("Calibration cancelled because the charger was disconnected.")
        }
        guard (0...100).contains(sample.percent), sample.temperature.isFinite, (-10...70).contains(sample.temperature), (-5...30).contains(now.timeIntervalSince(sample.date)) else {
            cancel(); throw SaverError("Calibration cancelled because battery readings are invalid.")
        }
        if phase == .discharging && sample.percent <= 15 { phase = .charging }
        if sample.temperature >= settings.heatPause {
            cancel(); throw SaverError("Calibration cancelled because the battery reached the heat threshold.")
        }
        if phase == .charging && sample.percent >= 100 { phase = .holding; holdStarted = now; holdStartedUptime = uptime }
        if phase == .holding {
            if sample.percent < 100 { phase = .charging; holdStarted = nil; holdStartedUptime = nil }
            else if let holdStartedUptime = holdStartedUptime, uptime - holdStartedUptime >= 3600 { phase = .completed; return nil }
        }
        switch phase {
        case .discharging: return CalibrationAction(allowCharging: false, useAdapter: false, reason: "Calibration · discharging to 15%")
        case .charging: return CalibrationAction(allowCharging: true, useAdapter: true, reason: "Calibration · charging to 100%")
        case .holding: return CalibrationAction(allowCharging: true, useAdapter: true, reason: "Calibration · holding full charge for one hour")
        default: return nil
        }
    }
}
