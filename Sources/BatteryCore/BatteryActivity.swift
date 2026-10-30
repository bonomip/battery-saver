import Foundation

public enum BatteryTone { case green, blue, yellow, red, neutral, gray }

/// Physical battery activity, independent of charging policy or helper intent.
public enum BatteryActivity {
    case unavailable, onBattery, pluggedIn, pluggedInDraining, charging

    public init(sample: BatterySample?) {
        guard let sample = sample else { self = .unavailable; return }
        if !sample.externalPower { self = .onBattery }
        else { self = sample.charging ? .charging : .pluggedIn }
    }
    public var title: String {
        switch self {
        case .unavailable: return "Battery status unavailable"
        case .onBattery: return "On battery"
        case .pluggedIn: return "Plugged in · not charging"
        case .charging: return "Charging"
        case .pluggedInDraining: return "Plugged in · battery draining"
        }
    }
    public var isCharging: Bool {
        if case .charging = self { return true }
        return false
    }
    public func tone(percent: Int?) -> BatteryTone {
        guard let percent = percent, (0...100).contains(percent) else { return .gray }
        if case .unavailable = self { return .gray }
        if isCharging { return .green }
        if percent < 15 { return .red }
        if case .pluggedIn = self { return .blue }
        if case .pluggedInDraining = self { return .yellow }
        return percent < 45 ? .yellow : .neutral
    }
}
