import Foundation

/// The daemon's lifecycle logic, independent of root privileges and IOKit.
/// Ownership is checked afresh before every tick, sleep and shutdown operation.
public final class HelperController {
    private let session: ProtectionSession
    private let backend: String
    private let readSettings: () throws -> Settings
    private let readBattery: () throws -> BatterySample
    private let checkConflict: () throws -> Bool
    private let readCommand: () -> CalibrationCommand?
    private var inbox: CalibrationInbox
    private var dischargeInbox: DischargeInbox
    private let readDischarge: () -> DischargeCommand?
    private var dischargeCommandID: UUID?
    private var dischargeCommandError: String?
    private var settings = Settings(enabled: false)
    private var running = true
    private var sleeping = false
    private var needsDisabledRestore = true

    public init(hardware: ChargingHardware, backend: String, existingCommand: CalibrationCommand?,
                readSettings: @escaping () throws -> Settings, readBattery: @escaping () throws -> BatterySample,
                checkConflict: @escaping () throws -> Bool, readCommand: @escaping () -> CalibrationCommand?,
                adapterRecoveryRequired: Bool = false, persistAdapterRecovery: @escaping (Bool) throws -> Void = { _ in },
                existingDischarge: DischargeCommand? = nil, readDischarge: @escaping () -> DischargeCommand? = { nil }) {
        session = ProtectionSession(hardware: hardware, adapterRecoveryRequired: adapterRecoveryRequired,
                                    persistAdapterRecovery: persistAdapterRecovery); self.backend = backend
        self.readSettings = readSettings; self.readBattery = readBattery
        self.checkConflict = checkConflict; self.readCommand = readCommand
        inbox = CalibrationInbox(existing: existingCommand)
        dischargeInbox = DischargeInbox(existing: existingDischarge)
        self.readDischarge = readDischarge
    }
    private func status(_ state: String, error: String? = nil, sample: BatterySample? = nil, allowed: Bool? = nil) -> HelperStatus {
        var result = HelperStatus(state: state, error: error, settings: settings, sample: sample, backend: backend,
                     chargingAllowed: allowed, calibrationActive: session.calibration.active, running: running)
        result.dischargeSupported = session.dischargeSupported
        result.dischargeTarget = session.discharge.active ? session.discharge.target : nil
        if dischargeCommandID != nil, let error = error { dischargeCommandError = error }
        result.dischargeCommandID = dischargeCommandID
        result.dischargeCommandError = dischargeCommandError
        return result
    }
    private func ownershipFailure() -> String? {
        do {
            return try checkConflict() ? "Another charging controller is running. Stop it before using Battery Saver." : nil
        } catch { return "Cannot verify controller ownership: \(error.localizedDescription)" }
    }
    private func yieldControl(_ reason: String) -> HelperStatus {
        var detail = reason
        do { try session.relinquish() }
        catch { detail += " Restoring our adapter input also failed: \(error.localizedDescription)" }
        return status("Protection unverified", error: detail)
    }
    public func tick() -> HelperStatus {
        guard running else { return status("Helper stopped") }
        guard !sleeping else { return status("Sleeping") }
        // This must precede settings/sensor reads: their failures must never
        // trigger recovery writes while another controller owns the hardware.
        if let failure = ownershipFailure() { return yieldControl(failure) }
        var sample: BatterySample?
        do {
            let newSettings = try readSettings(); try newSettings.validate(); settings = newSettings
            sample = try readBattery()
            let calibrationAction = readCommand().flatMap { inbox.consume($0) }
            let dischargeCommand = readDischarge().flatMap { dischargeInbox.consume($0) }
            if let command = dischargeCommand { dischargeCommandID = command.id; dischargeCommandError = nil }
            if calibrationAction == false || dischargeCommand?.target == nil && dischargeCommand != nil {
                session.cancelDischarge(); session.cancelCalibration()
            } else if calibrationAction == true && dischargeCommand != nil {
                throw SaverError("Simultaneous operation requests rejected. Retry one operation.")
            } else if let command = dischargeCommand, let target = command.target, let sample = sample {
                try session.startDischarge(sample: sample, settings: settings, target: target)
            }
            if let start = calibrationAction, dischargeCommand == nil {
                if start && settings.enabled {
                    guard let sample = sample, sample.externalPower, sample.temperature <= settings.heatResume else {
                        throw SaverError("Calibration requires the charger and a cool battery.")
                    }
                    try session.startCalibration()
                } else { session.cancelCalibration() }
            }
        } catch {
            session.cancelDischarge()
            session.cancelCalibration()
            var detail = error.localizedDescription
            if settings.enabled || needsDisabledRestore {
                do { try session.recover(sample: sample, settings: settings) }
                catch { detail += " Recovery also failed: \(error.localizedDescription)" }
            }
            return status("Protection needs attention", error: detail, sample: sample)
        }
        guard let sample = sample else { return status("Battery unavailable", error: "No battery sample") }
        if !settings.enabled && !needsDisabledRestore {
            return status("Protection off · macOS controls charging", sample: sample, allowed: true)
        }
        if settings.enabled { needsDisabledRestore = true }
        do {
            let decision = try session.update(sample, settings: settings)
            if !settings.enabled { needsDisabledRestore = false }
            return status(decision.reason, sample: sample, allowed: decision.allowCharging)
        } catch {
            // ProtectionSession has already attempted recovery. Do not issue
            // a second independent set of hardware writes for the same failure.
            return status("Protection needs attention", error: error.localizedDescription, sample: sample)
        }
    }
    public func sleep() -> HelperStatus {
        guard running else { return status("Helper stopped") }
        sleeping = true
        if let failure = ownershipFailure() { return yieldControl(failure) }
        var detail: String?
        do { let latest = try readSettings(); try latest.validate(); settings = latest }
        catch { detail = error.localizedDescription }
        do { try session.sleep(settings: settings) }
        catch { detail = [detail, error.localizedDescription].compactMap { $0 }.joined(separator: "; ") }
        return status(settings.enabled ? "Sleeping · charging paused" : "Sleeping · macOS controls charging",
                      error: detail, allowed: detail == nil ? !settings.enabled : nil)
    }
    public func wake() -> HelperStatus {
        // Sleep pauses the hardware, not the charge cycle. Preserve its
        // hysteresis latch, then recheck current limits, heat and ownership.
        sleeping = false; return tick()
    }
    public func stop() -> HelperStatus {
        running = false
        if let failure = ownershipFailure() { return yieldControl(failure) }
        session.cancelDischarge()
        session.cancelCalibration()
        do { try session.restore(); return status("Helper stopped · normal charging restored", allowed: true) }
        catch { return status("Helper stopped · restoration failed", error: error.localizedDescription) }
    }
}
