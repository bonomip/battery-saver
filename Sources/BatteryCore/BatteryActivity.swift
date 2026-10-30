import Foundation

/// Physical battery activity, independent of charging policy or helper intent.
public enum BatteryActivity {
    case unavailable, onBattery, pluggedIn, charging

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
        }
    }
    public var isCharging: Bool {
        if case .charging = self { return true }
        return false
    }
}
