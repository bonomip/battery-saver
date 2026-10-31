import AppKit
import SwiftUI
import BatteryCore
import IOKit.ps

final class BatteryModel: ObservableObject {
    private(set) var sample: BatterySample?
    private(set) var status: HelperStatus?
    @Published var error: String?
    @Published private var settingsDraft = SettingsDraft()
    var settings: BatteryCore.Settings { settingsDraft.settings }
    @Published private(set) var helperUpgrade: HelperUpgrade = .checking
    private var inspectedHelper = false
    private var installedHelperVersion: HelperVersion?
    private var updateAuthorization = HelperUpdateAuthorization()
    let helperSession = HelperAppSession()
    var helperRequiresLifecycleUpdate: Bool {
        helperInstalled && (installedHelperVersion == nil || helperUpgrade == .updateRequired)
    }
    var helperCompatible: Bool { helperUpgrade == .ready }
    var canControlHelper: Bool { !saving && helperCompatible }
    var calibrating: Bool { status?.isCurrent == true && status?.calibrationActive == true }
    var dischargeNeedsCancellation: Bool {
        status?.dischargeTarget != nil || (status?.adapterRecoveryRequired == true && !calibrating)
    }
    var canStartCalibration: Bool {
        canControlHelper && protectionVerified && !dischargeNeedsCancellation && !dischargePending && !hasDraft && !awaitingSettings
    }
    var canStartDischarge: Bool {
        canControlHelper && protectionVerified && !dischargeNeedsCancellation && !dischargePending && !hasDraft && !awaitingSettings &&
            !calibrating && status?.dischargeSupported == true && sample?.externalPower == true &&
            (sample?.percent ?? 0) > (status?.settings.upper ?? 100)
    }
    @Published var saving = false
    @Published var dischargePending = false
    @Published var inputErrors: Set<String> = []
    @Published private(set) var startAtLogin = false
    @Published var draftResetID = 0
    var awaitingSettings: Bool { settingsDraft.pendingSettings != nil }
    var hasDraft: Bool { settingsDraft.edited }
    private var timer: Timer?
    var isInterfaceVisible: () -> Bool = { true }
    private var lastDisplay: DisplaySnapshot?
    private var insights = BatteryInsights()
    private var insight: BatteryInsightResult?
    private var insightDate: Date?
    private var powerSource: CFRunLoopSource?
    var onRefresh: (() -> Void)?
    private var readError: String?
    var helperInstalled: Bool { FileManager.default.fileExists(atPath: Locations.helper) }
    var protectionVerified: Bool { helperCompatible && helperInstalled && sample != nil && status?.isCurrent == true && status?.settings.enabled == true }
    init() {
        helperSession.onChange = { [weak self] in self?.refresh(forcePublish: true) }
        startAtLogin = LoginStartup().isEnabled(app: Bundle.main.bundleURL)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.5
        if let timer = timer { RunLoop.main.add(timer, forMode: .common) }
        // React to macOS power changes without increasing periodic polling.
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            Unmanaged<BatteryModel>.fromOpaque(context).takeUnretainedValue().refresh()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source = powerSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
    deinit {
        timer?.invalidate()
        if let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
    }
    func refresh(forcePublish: Bool = false) {
        status = try? Locations.readStatus()
        if inspectedHelper {
            let state = HelperUpgrade.assess(installed: helperInstalled, version: installedHelperVersion,
                runningVersion: status?.isRecentRuntime == true ? status?.helperVersion : nil)
            if state != helperUpgrade { helperUpgrade = state }
        }
        do {
            let reading = try BatteryReader.readSnapshot()
            acceptReading(sample: reading.sample, telemetry: reading.telemetry)
            readError = nil
        } catch { sample = nil; insight = nil; insightDate = nil; readError = error.localizedDescription }
        var draft = settingsDraft
        if let message = draft.refresh(status: status) { error = message }
        if !helperInstalled { draft.helperUnavailable() }
        if draft != settingsDraft { settingsDraft = draft }
        let display = DisplaySnapshot(sample: sample, status: status, helperInstalled: helperInstalled,
            warning: warning, activity: activity.title, estimate: estimate)
        if forcePublish || display != lastDisplay {
            if isInterfaceVisible() { objectWillChange.send() }
            lastDisplay = display
        }
        onRefresh?()
    }
    private func acceptReading(sample: BatterySample, telemetry: BatteryTelemetry, now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.sample = sample
        let target: Int
        if helperInstalled && status?.isCurrent != true { target = 0 }
        else if let status = status, status.settings.enabled && !status.calibrationActive { target = status.settings.upper }
        else { target = 100 }
        insight = insights.update(sample: sample, telemetry: telemetry, targetPercent: target, now: now, uptime: uptime)
        insightDate = sample.date
    }
    var activity: BatteryActivity { sample?.date == insightDate ? (insight?.activity ?? BatteryActivity(sample: sample)) : BatteryActivity(sample: sample) }
    var estimate: String? { if status?.dischargeTarget != nil { return nil }; return sample?.date == insightDate ? insight?.estimate : nil }
    var batteryTone: BatteryTone {
        if status?.dischargeTarget != nil { return (sample?.percent ?? 100) < 15 ? .red : .yellow }
        return activity.tone(percent: sample?.percent)
    }
    var palette: AppPalette { AppPalette(tone: batteryTone) }
    func startDischarge() {
        guard canStartDischarge, let status = status else { return }
        setDischargeTarget(status.settings.upper)
    }
    func cancelDischarge() {
        setDischargeTarget(nil)
    }
    private func setDischargeTarget(_ target: Int?) {
        guard canControlHelper, !dischargePending else { return }
        dischargePending = true; error = nil
        helperSession.discharge(to: target, identifier: UUID()) { message in
            self.dischargePending = false
            self.error = message
            self.refresh(forcePublish: true)
        }
    }
    func startCalibration() {
        guard canStartCalibration else { return }
        authorize(["--calibrate"])
    }
    func discardChanges() {
        guard !saving, !awaitingSettings else { return }
        settingsDraft.discard()
        draftResetID += 1
        inputErrors.removeAll()
        error = nil
    }
    func configureLoginStartup() {
        let preferences = UserDefaults.standard
        if preferences.object(forKey: "startAtLogin") == nil || preferences.bool(forKey: "startAtLogin") {
            setStartAtLogin(true)
        }
    }
    func setStartAtLogin(_ enabled: Bool) {
        do {
            try LoginStartup().setEnabled(enabled, app: Bundle.main.bundleURL)
            startAtLogin = LoginStartup().isEnabled(app: Bundle.main.bundleURL)
            UserDefaults.standard.set(enabled, forKey: "startAtLogin")
        } catch { self.error = "Start at login: \(error.localizedDescription)" }
    }
    var warning: String? {
        if let error = error { return error }
        if let error = helperSession.error { return error }
        if let message = helperUpgrade.warning { return message }
        if let readError = readError { return readError }
        guard helperInstalled else { return nil }
        guard let status = status else { return "Waiting for the background helper. Protection is unverified." }
        if let error = status.error { return error }
        if !status.running { return "Background helper stopped. Protection is unverified." }
        if !status.isCurrent { return "Background helper is not responding. Protection is unverified." }
        return nil
    }
    func authorize(_ arguments: [String]) {
        guard helperCompatible else { error = helperUpgrade.warning; return }
        runAuthorized(executable: Locations.helper, arguments: arguments)
    }
    func draft<Value>(_ keyPath: WritableKeyPath<BatteryCore.Settings, Value>) -> Binding<Value> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { self.settingsDraft.edit(keyPath, to: $0) })
    }
    func checkHelperCompatibility(offerUpdate: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async {
            let installed = FileManager.default.fileExists(atPath: Locations.helper)
            let version = installed ? (try? HelperVersion.read(executable: Locations.helper)) : nil
            DispatchQueue.main.async {
                self.installedHelperVersion = version
                self.inspectedHelper = true
                if version?.canStartAppSession == true {
                    self.helperSession.start { _ in
                        self.refresh(forcePublish: true)
                    }
                }
                self.refresh(forcePublish: true)
                if offerUpdate && self.helperUpgrade == .updateRequired {
                    let alert = NSAlert()
                    alert.messageText = "Update Battery Saver’s background helper?"
                    alert.informativeText = "Update to helper revision \(HelperVersion.current.revision). Your settings will be preserved. macOS will ask for administrator authorization."
                    alert.addButton(withTitle: "Update helper")
                    alert.addButton(withTitle: "Later")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn { self.updateHelper() }
                }
            }
        }
    }
    func updateHelper() {
        guard helperUpgrade == .updateRequired, !saving, updateAuthorization.begin() else { return }
        manageHelper("update", helperUpdate: true)
    }
    func installHelper() { manageHelper("install") }
    func removeHelper() { manageHelper("uninstall") }
    private func manageHelper(_ action: String, helperUpdate: Bool = false) {
        guard let script = Bundle.main.path(forResource: "helper", ofType: "sh") else {
            if helperUpdate { _ = updateAuthorization.finish(succeeded: false, cancelled: false) }
            error = "Helper manager is missing from this app bundle."; return
        }
        runAuthorized(executable: "/bin/zsh", arguments: [script, action], helperUpdate: helperUpdate)
    }
    private func runAuthorized(executable: String, arguments: [String], configuration: Bool = false, helperUpdate: Bool = false) {
        guard !saving else { return }
        saving = true; error = nil
        AuthorizedCommand.run(executable: executable, arguments: arguments) { result in
            self.saving = false; self.error = result.error
            if result.succeeded && arguments.last == "uninstall" { self.helperSession.invalidate() }
            if configuration { self.settingsDraft.authorizationFinished(succeeded: result.succeeded, cancelled: result.cancelled) }
            if helperUpdate {
                _ = self.updateAuthorization.finish(succeeded: result.succeeded, cancelled: result.cancelled)
            }
            self.checkHelperCompatibility()
            self.refresh()
        }
    }

    func save() {
        guard helperCompatible else { error = helperUpgrade.warning; return }
        guard !saving else { return }
        guard inputErrors.isEmpty else { error = "Enter whole-number percentages in the allowed ranges before applying."; return }
        let submitted: BatteryCore.Settings
        do { submitted = try settingsDraft.beginApply() } catch { self.error = error.localizedDescription; return }
        var arguments = ["--configure", submitted.enabled ? "1" : "0", "\(submitted.lower)", "\(submitted.upper)", "\(submitted.heatPause)", "\(submitted.heatResume)"]
        if status?.sleepControlAvailable == true { arguments.append(submitted.keepAwakeUntilLimit ? "1" : "0") }
        runAuthorized(executable: Locations.helper, arguments: arguments, configuration: true)
    }
}
