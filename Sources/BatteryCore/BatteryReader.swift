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
        try readSnapshot(includeEstimates: false).sample
    }
    public static func readSnapshot() throws -> (sample: BatterySample, telemetry: BatteryTelemetry) {
        try readSnapshot(includeEstimates: true)
    }
    private static func readSnapshot(includeEstimates: Bool) throws -> (sample: BatterySample, telemetry: BatteryTelemetry) {
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
        let sample = BatterySample(date: Date(), percent: capacity.intValue, temperature: try celsius(raw: rawTemp.doubleValue), externalPower: ac.boolValue, charging: charging.boolValue,
                             currentMA: number("Amperage")?.intValue, voltageMV: number("Voltage")?.intValue,
                             cycles: number("CycleCount")?.intValue, healthPercent: design > 0 && full > 0 ? full / design * 100 : nil)
        var minutesToFull: Int?
        var minutesToEmpty: Int?
        if includeEstimates, let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue == sample.charging,
                      description[kIOPSPowerSourceStateKey] as? String == (sample.externalPower ? kIOPSACPowerValue : kIOPSBatteryPowerValue) else { continue }
                minutesToFull = (description[kIOPSTimeToFullChargeKey] as? NSNumber)?.intValue
                minutesToEmpty = (description[kIOPSTimeToEmptyKey] as? NSNumber)?.intValue
                break
            }
        }
        func validMinutes(_ value: Int?) -> Int? {
            guard let value = value, value > 0, value != 65535 else { return nil }
            return value
        }
        let sensorDate = ["UserVisiblePathUpdated", "UpdateTime"].compactMap { key -> Date? in
            guard let value = number(key)?.doubleValue, value.isFinite, value > 0 else { return nil }
            return Date(timeIntervalSince1970: value)
        }.first
        let telemetry = BatteryTelemetry(sensorDate: sensorDate, currentMA: sample.currentMA,
                                         remainingMAH: number("AppleRawCurrentCapacity")?.doubleValue,
                                         fullMAH: number("AppleRawMaxCapacity")?.doubleValue,
                                         percent: sample.percent, externalPower: sample.externalPower, charging: sample.charging,
                                         minutesToFull: validMinutes(minutesToFull), minutesToEmpty: validMinutes(minutesToEmpty))
        return (sample, telemetry)
    }
}
