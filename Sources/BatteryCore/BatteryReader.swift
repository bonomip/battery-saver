import Foundation
import IOKit

public enum BatteryReader {
    public static func celsius(raw: Double) throws -> Double {
        // AppleSmartBattery Temperature on this M1 uses tenths of kelvin.
        let value = raw / 10 - 273.15
        guard value.isFinite, (-10...70).contains(value) else { throw SaverError("Battery temperature is unavailable or has unsupported units.") }
        return value
    }
    public static func read() throws -> BatterySample {
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
        return BatterySample(date: Date(), percent: capacity.intValue, temperature: try celsius(raw: rawTemp.doubleValue), externalPower: ac.boolValue, charging: charging.boolValue,
                             currentMA: number("Amperage")?.intValue, voltageMV: number("Voltage")?.intValue,
                             cycles: number("CycleCount")?.intValue, healthPercent: design > 0 && full > 0 ? full / design * 100 : nil)
    }
}
