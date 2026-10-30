import Foundation

/// A bounded, one-shot operation. Adapter ownership remains in ProtectionSession.
public struct ForcedDischarge {
    public private(set) var target: Int?
    private var originalSettings: Settings?
    private var started = 0.0
    private var progressed = 0.0
    private var lastTime = 0.0
    private var lowest = 101
    public var active: Bool { target != nil }
    public init() {}
    public mutating func cancel() { target = nil; originalSettings = nil }
    public mutating func start(sample: BatterySample, settings: Settings, target: Int,
                               now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        try settings.validate()
        guard !active, settings.enabled, target == settings.upper, sample.externalPower,
              sample.percent > target, sample.percent <= 100, sample.temperature.isFinite,
              sample.temperature >= -10, sample.temperature <= settings.heatResume,
              (-5...30).contains(now.timeIntervalSince(sample.date)), uptime.isFinite, uptime >= 0 else {
            throw SaverError("Discharge requires fresh readings, a cool battery above the applied limit, and connected power.")
        }
        self.target = target; originalSettings = settings
        started = uptime; progressed = uptime; lastTime = uptime; lowest = sample.percent
    }
    public mutating func step(sample: BatterySample, settings: Settings, now: Date = Date(),
                              uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Bool {
        guard let target = target else { return false }
        guard originalSettings == settings else { cancel(); return false }
        guard (0...100).contains(sample.percent), sample.temperature.isFinite,
              (-10..<settings.heatPause).contains(sample.temperature),
              (-5...30).contains(now.timeIntervalSince(sample.date)), uptime.isFinite,
              uptime >= lastTime, uptime - started < 8 * 3600 else {
            cancel(); throw SaverError("Discharge cancelled: unsafe readings or elapsed-time limit.")
        }
        lastTime = uptime
        if sample.percent <= target { cancel(); return false }
        if sample.percent < lowest { lowest = sample.percent; progressed = uptime }
        guard uptime - progressed < 1800 else { cancel(); throw SaverError("Discharge cancelled after 30 minutes without progress.") }
        return true
    }
}

public struct DischargeCommand: Codable {
    public let id: UUID
    public let date: Date
    public let target: Int?
    public init(id: UUID = UUID(), date: Date = Date(), target: Int?) { self.id = id; self.date = date; self.target = target }
}
public struct DischargeInbox {
    private var seen: UUID?
    public init(existing: DischargeCommand? = nil) { seen = existing?.id }
    public mutating func consume(_ command: DischargeCommand, now: Date = Date()) -> DischargeCommand? {
        guard command.id != seen else { return nil }; seen = command.id
        guard command.target == nil || (0...30).contains(now.timeIntervalSince(command.date)) else { return nil }
        return command
    }
}
