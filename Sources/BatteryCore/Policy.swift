import Foundation

public struct SaverError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct Settings: Codable, Equatable {
    public var enabled: Bool
    public var lower: Int
    public var upper: Int
    public var heatPause: Double
    public var heatResume: Double
    public init(enabled: Bool = true, lower: Int = 75, upper: Int = 80, heatPause: Double = 38, heatResume: Double = 35) {
        self.enabled = enabled; self.lower = lower; self.upper = upper
        self.heatPause = heatPause; self.heatResume = heatResume
    }
    public func validate() throws {
        guard lower >= 20, upper <= 100, lower < upper,
              heatPause.isFinite, heatResume.isFinite,
              (30...45).contains(heatPause), (25...42).contains(heatResume), heatResume <= heatPause - 2 else {
            throw SaverError("Invalid settings: charge range must be 20–100%, with a lower restart point; temperature thresholds need at least a 2°C gap.")
        }
    }
}

public struct BatterySample: Codable {
    public var date: Date
    public let percent: Int
    public let temperature: Double
    public let externalPower: Bool
    public let charging: Bool
    public let currentMA: Int?
    public let voltageMV: Int?
    public let cycles: Int?
    public let healthPercent: Double?
    public init(date: Date, percent: Int, temperature: Double, externalPower: Bool, charging: Bool, currentMA: Int?, voltageMV: Int?, cycles: Int?, healthPercent: Double?) {
        self.date = date; self.percent = percent; self.temperature = temperature
        self.externalPower = externalPower; self.charging = charging; self.currentMA = currentMA
        self.voltageMV = voltageMV; self.cycles = cycles; self.healthPercent = healthPercent
    }
}

public struct Decision {
    public let allowCharging: Bool
    public let reason: String
}

public struct ChargePolicy {
    private var charging = false
    private var hot = false
    private var initialized = false
    public init() {}
    public mutating func evaluate(_ sample: BatterySample, settings: Settings, now: Date = Date()) throws -> Decision {
        try settings.validate()
        if !settings.enabled { charging = false; hot = false; initialized = false; return Decision(allowCharging: true, reason: "Protection off · macOS controls charging") }
        guard (0...100).contains(sample.percent), sample.temperature.isFinite,
              (-10...70).contains(sample.temperature), (-5...30).contains(now.timeIntervalSince(sample.date)) else {
            throw SaverError("Battery readings are invalid or stale; protection cannot be verified.")
        }
        if !initialized { hot = sample.temperature > settings.heatResume; initialized = true }
        if sample.temperature >= settings.heatPause { hot = true }
        if sample.temperature <= settings.heatResume { hot = false }
        if !sample.externalPower { charging = false; return Decision(allowCharging: true, reason: "On battery") }
        if hot { charging = false; return Decision(allowCharging: false, reason: "Cooling · resumes at \(Int(settings.heatResume))°C") }
        if sample.percent >= settings.upper { charging = false }
        else if sample.percent <= settings.lower { charging = true }
        return Decision(allowCharging: charging, reason: charging ? "Charging to \(settings.upper)%" : "Paused · resumes at \(settings.lower)%")
    }
}

public struct HelperStatus: Codable {
    public var date: Date
    public var state: String
    public var error: String?
    public var settings: Settings
    public var sample: BatterySample?
    public var backend: String
    public var chargingAllowed: Bool?
    public var calibrationActive: Bool
    public var running: Bool
    public var isCurrent: Bool { running && error == nil && (-5...30).contains(Date().timeIntervalSince(date)) }
    public init(date: Date = Date(), state: String, error: String?, settings: Settings, sample: BatterySample?, backend: String, chargingAllowed: Bool?, calibrationActive: Bool = false, running: Bool = true) {
        self.date = date; self.state = state; self.error = error; self.settings = settings
        self.sample = sample; self.backend = backend; self.chargingAllowed = chargingAllowed
        self.calibrationActive = calibrationActive
        self.running = running
    }
}

public enum Locations {
    public static let directory = "/Library/Application Support/BatterySaver"
    public static let settings = directory + "/settings.json"
    public static let status = directory + "/status.json"
    public static let helper = directory + "/battery-saver-helper"
    public static let label = "local.paolo.battery-saver"
    public static func readSettings() throws -> Settings {
        let value = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: URL(fileURLWithPath: settings)))
        try value.validate()
        return value
    }
}
