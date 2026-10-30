import Foundation

public protocol ChargingHardware: AnyObject {
    func setAllowed(_ allowed: Bool) throws
    func adapterSupported() -> Bool
    func setAdapter(_ enabled: Bool) throws
}
extension ChargeGate: ChargingHardware {}

/// Shared by the real daemon and integration tests. All calls run serially.
public final class ProtectionSession {
    private let hardware: ChargingHardware
    private var policy = ChargePolicy()
    public private(set) var discharge = ForcedDischarge()
    public var dischargeSupported: Bool { hardware.adapterSupported() }
    public func startDischarge(sample: BatterySample, settings: Settings, target: Int) throws {
        guard !calibration.active, hardware.adapterSupported() else { throw SaverError("Discharge unavailable during calibration or on unsupported hardware.") }
        try discharge.start(sample: sample, settings: settings, target: target)
    }
    public func cancelDischarge() { discharge.cancel() }
    private let persistAdapterRecovery: (Bool) throws -> Void
    public private(set) var calibration = Calibration()
    public private(set) var adapterMayBeDisabled = false
    public init(hardware: ChargingHardware, adapterRecoveryRequired: Bool = false,
                persistAdapterRecovery: @escaping (Bool) throws -> Void = { _ in }) {
        self.hardware = hardware; self.adapterMayBeDisabled = adapterRecoveryRequired
        self.persistAdapterRecovery = persistAdapterRecovery
    }
    public func startCalibration() throws {
        guard hardware.adapterSupported() else { throw SaverError("Calibration adapter control is unsupported.") }
        guard !discharge.active else { throw SaverError("Cancel discharge before calibration.") }
        guard !calibration.active else { return }
        calibration.start()
    }
    public func cancelCalibration() { calibration.cancel() }
    public func relinquish() throws {
        discharge.cancel()
        calibration.cancel()
        if adapterMayBeDisabled { try setAdapter(true) }
    }
    public func resetPolicy() { policy = ChargePolicy() }
    private func setAdapter(_ enabled: Bool) throws {
        // A failed write may still have reached the controller. Retain ownership
        // until a later successful restoration confirms adapter input is back.
        if !enabled && !adapterMayBeDisabled {
            // Commit recovery intent before the hardware write, so a process
            // crash cannot leave the next helper unaware of our adapter cut.
            try persistAdapterRecovery(true)
            adapterMayBeDisabled = true
        }
        try hardware.setAdapter(enabled)
        if enabled && adapterMayBeDisabled {
            try persistAdapterRecovery(false)
            adapterMayBeDisabled = false
        }
    }
    public func restore() throws {
        discharge.cancel()
        try recover(sample: nil, settings: Settings(enabled: false))
    }
    public func recover(sample: BatterySample?, settings: Settings) throws {
        discharge.cancel()
        var failures: [String] = []
        var allowCharging = true
        if !settings.enabled {
            policy = ChargePolicy()
        } else if let sample = sample {
            // Adapter restoration makes the pre-restoration AC flag obsolete,
            // particularly after calibration deliberately disconnected input.
            let restoredSample = BatterySample(date: sample.date, percent: sample.percent,
                temperature: sample.temperature, externalPower: true, charging: sample.charging,
                currentMA: sample.currentMA, voltageMV: sample.voltageMV,
                cycles: sample.cycles, healthPercent: sample.healthPercent)
            do { allowCharging = try policy.evaluate(restoredSample, settings: settings).allowCharging }
            catch {
                // Invalid readings cannot establish the charge limit. Preserve
                // the existing conservative thermal fallback without cooling
                // the policy's latch using an invalid sample.
                let warm = sample.temperature.isFinite && sample.temperature >= settings.heatResume && sample.temperature <= 70 && abs(sample.date.timeIntervalSinceNow) <= 30
                allowCharging = !warm
            }
        }
        // Attempt both restorations even if the first fails.
        if hardware.adapterSupported() {
            do { try setAdapter(true) } catch { failures.append(error.localizedDescription) }
        }
        do { try hardware.setAllowed(allowCharging) } catch { failures.append(error.localizedDescription) }
        if !failures.isEmpty { throw SaverError(failures.joined(separator: "; ")) }
    }
    public func sleep(settings: Settings) throws {
        discharge.cancel()
        calibration.cancel()
        var failures: [String] = []
        if hardware.adapterSupported() {
            do { try setAdapter(true) } catch { failures.append(error.localizedDescription) }
        }
        do { try hardware.setAllowed(!settings.enabled) } catch { failures.append(error.localizedDescription) }
        if !failures.isEmpty { throw SaverError(failures.joined(separator: "; ")) }
    }
    public func update(_ sample: BatterySample, settings: Settings) throws -> Decision {
        do {
            try settings.validate()
            if !settings.enabled { calibration.cancel(); discharge.cancel() }
            if try discharge.step(sample: sample, settings: settings) {
                try hardware.setAllowed(false)
                try setAdapter(false)
                return Decision(allowCharging: false, reason: "Discharging to \(settings.upper)%")
            }
            if let action = try calibration.step(sample, settings: settings) {
                if !action.allowCharging { try hardware.setAllowed(false) }
                try setAdapter(action.useAdapter)
                if action.allowCharging { try hardware.setAllowed(true) }
                return Decision(allowCharging: action.allowCharging, reason: action.reason)
            }
            let restoredOurAdapter = adapterMayBeDisabled
            if hardware.adapterSupported() { try setAdapter(true) }
            // A sample taken while we cut adapter input still says "on battery"
            // for this tick. Do not let that bypass the charge cap on cancellation.
            let policySample = restoredOurAdapter ? BatterySample(date: sample.date, percent: sample.percent,
                temperature: sample.temperature, externalPower: true, charging: sample.charging,
                currentMA: sample.currentMA, voltageMV: sample.voltageMV,
                cycles: sample.cycles, healthPercent: sample.healthPercent) : sample
            let decision = try policy.evaluate(policySample, settings: settings)
            try hardware.setAllowed(decision.allowCharging)
            return decision
        } catch {
            discharge.cancel()
            calibration.cancel()
            var message = error.localizedDescription
            do { try recover(sample: sample, settings: settings) } catch { message += " Restoration also failed: \(error.localizedDescription)" }
            throw SaverError(message)
        }
    }
}
