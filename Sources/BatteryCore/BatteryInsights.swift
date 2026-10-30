import Foundation

/// Optional physical measurements. Missing values never imply zero current or capacity.
public struct BatteryTelemetry {
    public var sensorDate: Date?
    public var currentMA: Int?
    public var remainingMAH: Double?
    public var fullMAH: Double?
    public var percent: Int
    public var externalPower: Bool
    public var charging: Bool
    public var minutesToFull: Int?
    public var minutesToEmpty: Int?

    public init(sensorDate: Date?, currentMA: Int?, remainingMAH: Double?, fullMAH: Double?, percent: Int, externalPower: Bool, charging: Bool, minutesToFull: Int? = nil, minutesToEmpty: Int? = nil) {
        self.sensorDate = sensorDate
        self.currentMA = currentMA
        self.remainingMAH = remainingMAH
        self.fullMAH = fullMAH
        self.percent = percent
        self.externalPower = externalPower
        self.charging = charging
        self.minutesToFull = minutesToFull
        self.minutesToEmpty = minutesToEmpty
    }
}

public struct BatteryInsightResult {
    public let activity: BatteryActivity
    public let estimate: String?
}

/// Session-local evidence; cached registry values cannot accumulate evidence.
public struct BatteryInsights {
    private var evidenceAfter: Date?
    private var previousPower: Bool?
    private var previousTarget: Int?
    private var previousNow: Date?
    private var previousUptime: TimeInterval?
    private var lastSensor: Date?
    private var negativeCount = 0
    private var draining = false
    private var smoothedCurrent: Double?
    private var rateCount = 0
    private var direction = 0

    public init() {}

    public mutating func update(sample: BatterySample, telemetry: BatteryTelemetry, targetPercent: Int, now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> BatteryInsightResult {
        guard (0...100).contains(sample.percent), telemetry.percent == sample.percent,
              telemetry.externalPower == sample.externalPower, telemetry.charging == sample.charging else {
            clear()
            return BatteryInsightResult(activity: BatteryActivity(sample: sample), estimate: nil)
        }
        let powerChanged = previousPower.map { $0 != sample.externalPower } ?? false
        if powerChanged { evidenceAfter = now }
        let wallInterval = previousNow.map { now.timeIntervalSince($0) }
        if wallInterval.map({ $0 < 0 }) == true { evidenceAfter = now }
        let monotonicInterval = previousUptime.map { uptime - $0 }
        let reset = previousPower != sample.externalPower || previousTarget != targetPercent ||
            (wallInterval.map { $0 < 0 || $0 > 120 } ?? false) ||
            (monotonicInterval.map { $0 < 0 || $0 > 120 } ?? false) ||
            (wallInterval != nil && monotonicInterval != nil && abs(wallInterval! - monotonicInterval!) > 30)
        if reset { clear() }
        previousPower = sample.externalPower
        previousTarget = targetPercent
        previousNow = now
        previousUptime = uptime
        let fresh = telemetry.sensorDate.map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= 90 && (evidenceAfter == nil || $0 >= evidenceAfter!) } ?? false
        let distinct = fresh && telemetry.sensorDate.map { lastSensor == nil || $0 > lastSensor! } == true
        if !fresh {
            clear()
        } else if distinct {
            lastSensor = telemetry.sensorDate
            if let current = telemetry.currentMA, abs(Double(current)) <= 30_000 {
                if current < -100 { negativeCount += 1; draining = negativeCount >= 2 }
                else if current >= -50 { negativeCount = 0; draining = false }
                else if !draining { negativeCount = 0 }
                let sign = current > 100 ? 1 : (current < -100 ? -1 : 0)
                if sign != direction || sign == 0 { smoothedCurrent = nil; rateCount = 0 }
                direction = sign
                if sign != 0, abs(Double(current)) <= 30_000 {
                    smoothedCurrent = smoothedCurrent.map { $0 * 0.65 + Double(current) * 0.35 } ?? Double(current)
                    rateCount += 1
                } else { smoothedCurrent = nil; rateCount = 0 }
            } else { clearRates(); negativeCount = 0; draining = false }
        }
        let contradictsCharging = fresh && telemetry.currentMA.map { $0 < -100 && Double($0) >= -30_000 } == true
        let activity: BatteryActivity
        if sample.externalPower && draining { activity = .pluggedInDraining }
        else if sample.externalPower && sample.charging && contradictsCharging { activity = .pluggedIn }
        else { activity = BatteryActivity(sample: sample) }
        let charging = activity.isCharging && (1...100).contains(targetPercent) && sample.percent < targetPercent
        let discharging = !sample.externalPower || activity == .pluggedInDraining
        guard charging || discharging else { return BatteryInsightResult(activity: activity, estimate: nil) }
        var minutes: Double?
        if fresh && charging && targetPercent == 100 { minutes = validMinutes(telemetry.minutesToFull) }
        if fresh && !sample.externalPower { minutes = validMinutes(telemetry.minutesToEmpty) }
        if minutes == nil, fresh, rateCount >= 2, let current = smoothedCurrent,
           let full = telemetry.fullMAH, let remaining = telemetry.remainingMAH,
           full.isFinite, remaining.isFinite, full > 0, full <= 100_000, remaining >= 0, remaining <= full,
           (charging ? current > 100 : current < -100) {
            // Raw capacity percentage differs from macOS percentage. Project the
            // displayed percentage gap, not an unrelated raw state-of-charge target.
            let amount = charging ? full * Double(targetPercent - sample.percent) / 100 : remaining
            if amount > 0 { minutes = amount / abs(current) * 60 }
        }
        let estimate: String
        if let minutes = minutes, minutes.isFinite, minutes > 0, minutes <= 48 * 60 {
            let duration = Self.duration(minutes)
            estimate = charging ? "\(duration) to \(targetPercent)%" : "\(duration) remaining"
        } else { estimate = "Estimating…" }
        return BatteryInsightResult(activity: activity, estimate: estimate)
    }

    private func validMinutes(_ value: Int?) -> Double? {
        guard let value = value, value > 0, value != 65535, value <= 48 * 60 else { return nil }
        return Double(value)
    }
    private mutating func clearRates() { smoothedCurrent = nil; rateCount = 0; direction = 0 }
    private mutating func clear() { lastSensor = nil; negativeCount = 0; draining = false; clearRates() }
    private static func duration(_ minutes: Double) -> String {
        if minutes < 5 { return "Less than 5 min" }
        let rounded = Int((minutes / 5).rounded()) * 5
        if rounded < 60 { return "About \(rounded) min" }
        let hours = rounded / 60
        let rest = rounded % 60
        return rest == 0 ? "About \(hours)h" : "About \(hours)h \(rest) min"
    }
}
