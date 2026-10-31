import Foundation
import IOKit
import IOKit.ps

public enum BatteryReader {
    public static func celsius(raw: Double) throws -> Double {
        // AppleSmartBattery Temperature on this M1 uses tenths of kelvin.
        let value = raw / 10 - 273.15
        guard value.isFinite, (-10...70).contains(value) else { throw SaverError("Battery temperature is unavailable or has unsupported units.") }
        return value
    }
    public static func read() throws -> BatterySample {
        try readSnapshot(includeSystemStatus: false).sample
    }
    public static func readSnapshot() throws -> (sample: BatterySample, telemetry: BatteryTelemetry) {
        try readSnapshot(includeSystemStatus: true)
    }
    private static func readSnapshot(includeSystemStatus: Bool) throws -> (sample: BatterySample, telemetry: BatteryTelemetry) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { throw SaverError("No internal MacBook battery found.") }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any] else { throw SaverError("Cannot read battery sensors.") }
        func number(_ key: String) -> NSNumber? { values[key] as? NSNumber }
        guard let capacity = number("CurrentCapacity"), let rawTemp = number("Temperature"),
              let ac = number("ExternalConnected"), let charging = number("IsCharging"),
              (0...100).contains(capacity.intValue) else { throw SaverError("Required battery sensors are missing or unsupported.") }
        let design = number("DesignCapacity")?.doubleValue ?? 0
        let full = number("AppleRawMaxCapacity")?.doubleValue ?? 0
        let system = powerSourceState(rawCharging: charging.boolValue, externalPower: ac.boolValue,
                                      descriptions: includeSystemStatus ? powerSourceDescriptions() : [])
        let sample = BatterySample(date: Date(), percent: capacity.intValue, temperature: try celsius(raw: rawTemp.doubleValue), externalPower: ac.boolValue, charging: system.charging,
                             currentMA: number("Amperage")?.intValue, voltageMV: number("Voltage")?.intValue,
                             cycles: number("CycleCount")?.intValue, healthPercent: design > 0 && full > 0 ? full / design * 100 : nil)
        let sensorDate = ["UserVisiblePathUpdated", "UpdateTime"].compactMap { key -> Date? in
            guard let value = number(key)?.doubleValue, value.isFinite, value > 0 else { return nil }
            return Date(timeIntervalSince1970: value)
        }.first
        let telemetry = BatteryTelemetry(sensorDate: sensorDate, currentMA: sample.currentMA,
                                         remainingMAH: number("AppleRawCurrentCapacity")?.doubleValue,
                                         fullMAH: number("AppleRawMaxCapacity")?.doubleValue,
                                         percent: sample.percent, externalPower: sample.externalPower, charging: sample.charging,
                                         minutesToFull: system.minutesToFull, minutesToEmpty: system.minutesToEmpty)
        return (sample, telemetry)
    }

    struct PowerSourceState {
        let charging: Bool
        var minutesToFull: Int?
        var minutesToEmpty: Int?
    }
    /// Match the same internal battery and AC state before merging macOS status.
    /// The menu app follows the public charging flag, even when a raw flag lags it.
    static func powerSourceState(rawCharging: Bool, externalPower: Bool, descriptions: [[String: Any]]) -> PowerSourceState {
        for description in descriptions {
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSPowerSourceStateKey] as? String == (externalPower ? kIOPSACPowerValue : kIOPSBatteryPowerValue),
                  let charging = description[kIOPSIsChargingKey] as? NSNumber,
                  charging == NSNumber(value: 0) || charging == NSNumber(value: 1) else { continue }
            func minutes(_ key: String) -> Int? {
                guard let value = (description[key] as? NSNumber)?.intValue, value > 0, value != 65535 else { return nil }
                return value
            }
            return PowerSourceState(charging: charging.boolValue, minutesToFull: minutes(kIOPSTimeToFullChargeKey),
                                    minutesToEmpty: minutes(kIOPSTimeToEmptyKey))
        }
        return PowerSourceState(charging: rawCharging)
    }
    private static func powerSourceDescriptions() -> [[String: Any]] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return sources.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
    }
}
