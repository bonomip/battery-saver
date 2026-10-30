import Foundation
import IOKit
import IOKit.ps

// Temporary read-only latency diagnostic. The app does not use this polling rate.
// Compile: swiftc -module-cache-path .build/module-cache Scripts/trace_power.swift -o .build/trace-power
// Run: .build/trace-power 60 > Verification/power-transition.jsonl
let duration = min(300, max(1, Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60))
let start = ProcessInfo.processInfo.systemUptime
var last = ""
func record(_ trigger: String) {
    var fields: [String: Any] = [:]
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    if service != 0 {
        defer { IOObjectRelease(service) }
        for key in ["ExternalConnected", "AppleRawExternalConnected", "IsCharging", "CurrentCapacity", "Amperage"] {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                fields[key] = value
            }
        }
    }
    if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
        fields["publicPowerSource"] = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        if let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                if let details = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                    fields["publicCharging"] = details[kIOPSIsChargingKey]
                    fields["publicPercent"] = details[kIOPSCurrentCapacityKey]
                }
            }
        }
    }
    guard let comparison = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys) else { return }
    let state = String(decoding: comparison, as: UTF8.self)
    guard trigger != "poll" || state != last else { return }
    last = state
    fields["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - start
    fields["trigger"] = trigger
    if let data = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys) {
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    }
}
let general = IOPSNotificationCreateRunLoopSource({ _ in record("generalNotification") }, nil)?.takeRetainedValue()
let power = IOPSCreateLimitedPowerNotification({ _ in record("powerSourceNotification") }, nil)?.takeRetainedValue()
for source in [general, power].compactMap({ $0 }) { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
record("start")
let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in record("poll") }
RunLoop.main.run(until: Date().addingTimeInterval(duration))
timer.invalidate()
for source in [general, power].compactMap({ $0 }) { CFRunLoopSourceInvalidate(source) }
record("end")
