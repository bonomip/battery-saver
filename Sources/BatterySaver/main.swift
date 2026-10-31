import AppKit
import SwiftUI
import BatteryCore
import IOKit.ps
import Darwin

final class BatteryModel: ObservableObject {
    var sample: BatterySample?
    var status: HelperStatus?
    @Published var error: String?
    @Published private var settingsDraft = SettingsDraft()
    var settings: BatteryCore.Settings { settingsDraft.settings }
    @Published private(set) var helperUpgrade: HelperUpgrade = .checking
    private var inspectedHelper = false
    private var installedHelperVersion: HelperVersion?
    private var updateAuthorization = HelperUpdateAuthorization()
    var helperCompatible: Bool { helperUpgrade == .ready }
    @Published var saving = false
    @Published var dischargePending = false
    private var dischargeRequest: (UUID, Date)?
    @Published var inputErrors: Set<String> = []
    @Published private(set) var startAtLogin = false
    @Published var draftResetID = 0
    var awaitingSettings: Bool { settingsDraft.pendingSettings != nil }
    var hasDraft: Bool { settingsDraft.edited }
    var timer: Timer?
    var isInterfaceVisible: () -> Bool = { true }
    private var lastDisplay: DisplaySnapshot?
    private var insights = BatteryInsights()
    private var insight: BatteryInsightResult?
    private var insightDate: Date?
    private var powerSource: CFRunLoopSource?
    var onRefresh: (() -> Void)?
    var readError: String?
    var helperInstalled: Bool { FileManager.default.fileExists(atPath: Locations.helper) }
    var protectionVerified: Bool { helperCompatible && helperInstalled && sample != nil && status?.isCurrent == true && status?.settings.enabled == true }
    init() {
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
        status = (try? Data(contentsOf: URL(fileURLWithPath: Locations.status))).flatMap { try? JSONDecoder().decode(HelperStatus.self, from: $0) }
        if inspectedHelper {
            let state = HelperUpgrade.assess(installed: helperInstalled, version: installedHelperVersion,
                runningVersion: status?.running == true && (-5...30).contains(Date().timeIntervalSince(status?.date ?? .distantPast)) ? status?.helperVersion : nil)
            if state != helperUpgrade { helperUpgrade = state }
        }
        do {
            let reading = try BatteryReader.readSnapshot()
            acceptReading(sample: reading.sample, telemetry: reading.telemetry)
            readError = nil
        } catch { sample = nil; insight = nil; insightDate = nil; readError = error.localizedDescription }
        if let (id, date) = dischargeRequest {
            if status?.dischargeCommandID == id && status?.running == true && (-5...30).contains(Date().timeIntervalSince(status?.date ?? .distantPast)) {
                dischargeRequest = nil; dischargePending = false
                if let failure = status?.dischargeCommandError { error = failure }
            } else if Date().timeIntervalSince(date) > 30 {
                dischargeRequest = nil; dischargePending = false
                error = "Discharge command was not acknowledged. Check the helper before retrying."
            }
        }
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
    func acceptReading(sample: BatterySample, telemetry: BatteryTelemetry, now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
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
        guard !dischargePending, !hasDraft, !awaitingSettings, !saving, let status = status, status.isCurrent,
              status.dischargeSupported, status.settings.enabled, !status.calibrationActive,
              let sample = sample, sample.externalPower, sample.percent > status.settings.upper else { return }
        let id = UUID()
        authorize(["--discharge", "\(status.settings.upper)", id.uuidString])
    }
    func cancelDischarge() {
        guard !saving else { return }
        authorize(["--cancel-discharge", UUID().uuidString])
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
    var state: String { activity.title }
    var warning: String? {
        if let error = error { return error }
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
        guard let script = Bundle.main.path(forResource: "helper", ofType: "sh") else {
            _ = updateAuthorization.finish(succeeded: false, cancelled: false)
            error = "Helper updater is missing from this app bundle."; return
        }
        runAuthorized(executable: "/bin/zsh", arguments: [script, "update"], helperUpdate: true)
    }
    func installHelper() {
        guard let script = Bundle.main.path(forResource: "helper", ofType: "sh") else { error = "Helper manager is missing from this app bundle."; return }
        runAuthorized(executable: "/bin/zsh", arguments: [script, "install"])
    }
    func removeHelper() {
        guard let script = Bundle.main.path(forResource: "helper", ofType: "sh") else { error = "Helper manager is missing from this app bundle."; return }
        runAuthorized(executable: "/bin/zsh", arguments: [script, "uninstall"])
    }
    private func runAuthorized(executable: String, arguments: [String], configuration: Bool = false, helperUpdate: Bool = false) {
        guard !saving else { return }
        saving = true; error = nil
        let command = ([executable] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"\(literal)\" with administrator privileges"]
            let output = Pipe(); process.standardError = output; process.standardOutput = FileHandle.nullDevice
            var message: String?
            var cancelled = false
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let detail = String(decoding: data, as: UTF8.self)
                    cancelled = detail.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("(-128)")
                    if !cancelled { message = detail }
                }
            } catch { message = error.localizedDescription }
            DispatchQueue.main.async {
                self.saving = false; self.error = message
                if arguments.first == "--discharge" || arguments.first == "--cancel-discharge" {
                    if message == nil && !cancelled, let id = UUID(uuidString: arguments.last ?? "") {
                        self.dischargeRequest = (id, Date()); self.dischargePending = true
                    }
                }
                if configuration { self.settingsDraft.authorizationFinished(succeeded: message == nil && !cancelled, cancelled: cancelled) }
                if helperUpdate {
                    _ = self.updateAuthorization.finish(succeeded: message == nil, cancelled: cancelled)
                }
                self.checkHelperCompatibility()
                self.refresh()
            }
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

struct ChargeThresholdControl: View {
    let accent: Color
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    @Binding var inputErrors: Set<String>
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).frame(width: 68, alignment: .leading)
                Slider(value: Binding(get: { Double(value) }, set: {
                    value = Int($0.rounded()); text = "\(value)"; inputErrors.remove(title)
                }), in: Double(range.lowerBound)...Double(range.upperBound))
                    .accentColor(accent).tint(accent)
                    .accessibilityLabel(title)
                TextField(title, text: $text)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 48)
                    .accessibilityLabel("\(title) percentage")
                Text("%")
            }.padding(.vertical, 3)
            if inputErrors.contains(title) {
                Text("Enter a whole number from \(range.lowerBound) to \(range.upperBound)%.")
                    .font(.caption).foregroundColor(AppPalette.error)
            }
        }
        .onAppear { text = "\(value)" }
        .onChange(of: text) { updated in
            if let number = Int(updated), range.contains(number) {
                inputErrors.remove(title)
                if value != number { value = number }
            } else { inputErrors.insert(title) }
        }
        .onChange(of: value) { updated in
            text = "\(updated)"; inputErrors.remove(title)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var item: NSStatusItem!
    private var statusPanel: StatusPanel?
    private let statusDismissal = StatusDismissal()
    var settingsWindow: NSWindow?
    private var menuTracking = false
    private var closingStatus = false
    private var statusGeneration = UUID()
    private var lastIconKey: String?
    let model = BatteryModel()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.configureLoginStartup()
        model.checkHelperCompatibility(offerUpdate: true)
        model.isInterfaceVisible = { [weak self] in
            guard let self = self else { return false }
            return self.menuTracking || self.settingsWindow?.isVisible == true
        }
        // Supply standard editing shortcuts for keyboard entry in the settings window.
        let mainMenu = NSMenu()
        let editEntry = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
                                     ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
                                     ("Select All", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editEntry.submenu = editMenu; mainMenu.addItem(editEntry); NSApp.mainMenu = mainMenu
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggleStatus)
        model.onRefresh = { [weak self] in self?.update() }; update()
    }
    func update() {
        guard let button = item.button else { return }
        let title = model.sample.map { "\($0.percent)%" } ?? "—"
        if !button.title.isEmpty { button.title = "" }
        let appearance = button.effectiveAppearance
        let key = "\(title)|\(model.activity.title)|\(model.batteryTone)|\(appearance.name.rawValue)"
        if key != lastIconKey {
            button.image = MenuBarBatteryIcon.image(percent: model.sample?.percent, activity: model.activity,
                tone: model.batteryTone, appearance: appearance)
            button.imagePosition = .imageOnly
            lastIconKey = key
        }
        if button.toolTip != model.state { button.toolTip = model.state }
    }
    @objc func toggleStatus() {
        if statusPanel?.isVisible == true { dismissStatus(); return }
        guard let button = item.button, let anchorWindow = button.window, let screen = anchorWindow.screen else { return }
        statusGeneration = UUID()
        menuTracking = true
        model.refresh(forcePublish: true)
        let host = QuickCardHost(rootView: QuickCard(model: model) { [weak self] in
            let pointer = NSEvent.mouseLocation
            self?.dismissStatus(animated: false)
            DispatchQueue.main.async { self?.openSettings(at: pointer) }
        })
        host.frame = NSRect(x: 0, y: 0, width: QuickCard.width, height: QuickCard.height)
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let panel = makeStatusPanel(content: host, anchor: anchor, visibleFrame: screen.visibleFrame)
        statusPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        statusDismissal.start(contains: { [weak self] event in
            guard let self = self else { return false }
            if event.window === self.statusPanel { return true }
            if let button = self.item.button, event.window === button.window {
                return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
            }
            return false
        }, anchorVisible: { [weak self] in
            guard let button = self?.item.button, let window = button.window,
                  window.isVisible, let screen = window.screen else { return false }
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let visible = rect.intersection(screen.frame)
            return !visible.isNull && visible.height >= rect.height * 0.5
        }, close: { [weak self] in self?.dismissStatus() })
    }
    private func dismissStatus(animated: Bool = true) {
        guard let panel = statusPanel, panel.isVisible, !closingStatus else { return }
        closingStatus = true
        statusDismissal.stop()
        if !animated {
            finishStatusDismissal()
            return
        }
        let generation = statusGeneration
        fadeStatusWindow(panel,
                         reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { [weak self] in
            guard let self = self, self.closingStatus, self.statusGeneration == generation else { return }
            self.finishStatusDismissal()
        }
    }
    private func finishStatusDismissal() {
        statusPanel?.orderOut(nil)
        statusPanel?.contentView = nil
        statusPanel = nil
        closingStatus = false
        statusDismissal.stop()
        menuTracking = false
    }
    func windowWillClose(_ notification: Notification) {
        settingsWindow?.contentViewController = nil
        settingsWindow = nil
    }
    @objc func openSettings() { openSettings(at: NSEvent.mouseLocation) }
    func openSettings(at pointer: NSPoint) {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Battery Saver Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: Panel(model: model))
            host.frame.size = NSSize(width: 680, height: 740)
            host.layoutSubtreeIfNeeded()
            host.frame.size = host.fittingSize
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.documentView = host
            window.contentView = scroll
            window.setContentSize(host.frame.size)
            let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
            if let screen = screen {
                window.setFrame(settingsWindowFrame(size: window.frame.size, pointer: pointer,
                    visibleFrame: screen.visibleFrame), display: false)
            }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: host.isFlipped ? 0 : max(0, host.frame.height - scroll.contentSize.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            settingsWindow = window
        }
        model.refresh(forcePublish: true)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--render-menu-icons" {
    app.setActivationPolicy(.prohibited)
    do { try renderMenuIconPreview(to: URL(fileURLWithPath: CommandLine.arguments[2])) }
    catch { fputs("Icon preview failed: \(error.localizedDescription)\n", stderr); exit(1) }
    print("Rendered menu icon states without opening a window.")
    exit(0)
}
if CommandLine.arguments.contains("--verify-window-placement") {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let pointer = NSPoint(x: 720, y: 600)
    let frame = settingsWindowFrame(size: NSSize(width: 680, height: 500), pointer: pointer, visibleFrame: screen)
    precondition(abs(frame.midX - pointer.x) < 0.01)
    precondition(abs(frame.maxY - pointer.y - frame.height * 0.25) < 0.01)
    for screen in [screen, NSRect(x: -1440, y: -300, width: 1440, height: 900)] {
        for point in [NSPoint(x: screen.minX, y: screen.minY), NSPoint(x: screen.maxX, y: screen.maxY)] {
            for size in [NSSize(width: 680, height: 740), NSSize(width: 2000, height: 2000)] {
                let placed = settingsWindowFrame(size: size, pointer: point, visibleFrame: screen)
                precondition(screen.contains(placed))
            }
        }
    }
    for dark in [false, true] {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let outline = MenuBarBatteryIcon.outlineColor(appearance: appearance).usingColorSpace(.sRGB)!
        func luminance(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let foreground = luminance(outline.redComponent)
        let background = luminance(dark ? 0.16 : 0.94)
        let contrast = (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
        precondition(contrast >= 7)
    }
    print("PASS: cursor anchor, screen-edge clamping, multiple screens, oversized frames, and light/dark outline contrast. No window displayed.")
    exit(0)
}
if CommandLine.arguments.contains("--verify-status-fade") {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
    var completed = 0
    fadeStatusWindow(window, reduceMotion: false) { completed += 1 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    precondition(completed == 1 && window.alphaValue == 0)
    window.alphaValue = 1
    fadeStatusWindow(window, reduceMotion: true) { completed += 1 }
    precondition(completed == 2 && window.alphaValue == 1)
    fadeStatusWindow(nil, reduceMotion: false) { completed += 1 }
    precondition(completed == 3)
    print("PASS: fade completes once; reduced-motion and missing-window paths close immediately. No window displayed.")
    exit(0)
}
if CommandLine.arguments.contains("--verify-status-dismissal") {
    for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
        precondition(StatusDismissal.shouldClose(type: type, keyCode: 0, inside: false))
        precondition(!StatusDismissal.shouldClose(type: type, keyCode: 0, inside: true))
    }
    precondition(StatusDismissal.shouldClose(type: .keyDown, keyCode: 53, inside: true))
    precondition(!StatusDismissal.shouldClose(type: .keyDown, keyCode: 0, inside: false))
    // Install/remove real AppKit monitors repeatedly; cleanup must be idempotent.
    let monitor = StatusDismissal()
    for _ in 0..<10 { monitor.start(contains: { _ in false }, close: {}); monitor.stop(); monitor.stop() }
    var closes = 0
    monitor.start(contains: { _ in false }, close: { closes += 1 })
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    NotificationCenter.default.post(name: NSApplication.didHideNotification, object: NSApp)
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    precondition(closes == 3)
    monitor.stop()
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    precondition(closes == 3)
    monitor.checkMenuBar(menuVisible: false, anchorVisible: true, close: { closes += 1 })
    precondition(closes == 3) // Initial fullscreen flag does not dismiss a visible anchor.
    monitor.checkMenuBar(menuVisible: true, anchorVisible: true, close: { closes += 1 })
    precondition(closes == 3)
    monitor.checkMenuBar(menuVisible: false, anchorVisible: true, close: { closes += 1 })
    precondition(closes == 4)
    monitor.stop()
    monitor.checkMenuBar(menuVisible: false, anchorVisible: false, close: { closes += 1 })
    precondition(closes == 5)
    monitor.start(contains: { _ in false }, anchorVisible: { false }, close: { closes += 1; monitor.stop() })
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    precondition(closes == 6)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    precondition(closes == 6) // No timer or monitor callbacks remain after close.
    print("PASS: outside/Escape, notifications, menu-bar transitions, real visibility timer and cleanup checks.")
    exit(0)
}
if CommandLine.arguments.contains("--verify-details-button") {
    app.setActivationPolicy(.prohibited)
    var actions = 0
    let host = QuickCardHost(rootView: QuickCard(model: BatteryModel()) { actions += 1 })
    host.frame = NSRect(x: 0, y: 0, width: QuickCard.width, height: QuickCard.height)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func findButton(_ view: NSView) -> DetailsActionButton? {
        if let button = view as? DetailsActionButton { return button }
        return view.subviews.compactMap { findButton($0) }.first
    }
    guard let button = findButton(host), button.bounds.width >= 28, button.bounds.height >= 28 else {
        fputs("FAIL: full-area details button is missing.\n", stderr); exit(1)
    }
    for point in [NSPoint(x: 2, y: 2), NSPoint(x: button.bounds.width - 2, y: 2),
                  NSPoint(x: 2, y: button.bounds.height - 2),
                  NSPoint(x: button.bounds.width - 2, y: button.bounds.height - 2),
                  NSPoint(x: button.bounds.midX, y: button.bounds.midY)] {
        let hit = host.hitTest(button.convert(point, to: host.superview))
        guard hit === button || hit?.isDescendant(of: button) == true else {
            fputs("FAIL: details button hit area has a gap.\n", stderr); exit(1)
        }
        button.performClick(nil)
    }
    guard actions == 5, button.acceptsFirstMouse(for: nil) else { exit(1) }
    print("PASS: corners and center hit the full-area native button; five actions delivered; first mouse accepted. No window displayed.")
    exit(0)
}
if CommandLine.arguments.contains("--verify-idle-refresh") {
    app.setActivationPolicy(.prohibited)
    let model = BatteryModel()
    model.isInterfaceVisible = { false }
    var updates = 0
    let observer = model.objectWillChange.sink { updates += 1 }
    let cpuStart = clock()
    for _ in 0..<100 { model.refresh() }
    let cpuMilliseconds = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC) * 1000
    guard updates == 0 else { fputs("FAIL: hidden refreshes still publish UI updates.\n", stderr); exit(1) }
    model.isInterfaceVisible = { true }
    model.refresh(forcePublish: true)
    guard updates == 1 else { fputs("FAIL: reopening does not refresh the interface.\n", stderr); exit(1) }
    withExtendedLifetime(observer) {}
    print("PASS: 100 hidden refreshes published zero UI updates; reopening published once. CPU milliseconds: \(cpuMilliseconds)")
    exit(0)
}
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--render-preview" {
    app.setActivationPolicy(.prohibited)
    let previewModel = BatteryModel()
    if let scenario = ProcessInfo.processInfo.environment["BATTERY_SAVER_PREVIEW_POWER"] {
        let old = previewModel.sample
        previewModel.sample = BatterySample(date: Date(), percent: old?.percent ?? 60, temperature: old?.temperature ?? 25,
            externalPower: scenario != "battery", charging: scenario == "charging", currentMA: nil, voltageMV: nil,
            cycles: old?.cycles, healthPercent: old?.healthPercent)
    }
    if let percent = Int(ProcessInfo.processInfo.environment["BATTERY_SAVER_PREVIEW_PERCENT"] ?? ""),
       (0...100).contains(percent), let old = previewModel.sample {
        previewModel.sample = BatterySample(date: Date(), percent: percent, temperature: old.temperature,
            externalPower: old.externalPower, charging: old.charging, currentMA: old.currentMA, voltageMV: old.voltageMV,
            cycles: old.cycles, healthPercent: old.healthPercent)
    }
    if let scenario = ProcessInfo.processInfo.environment["BATTERY_SAVER_PREVIEW_INSIGHT"], let old = previewModel.sample {
        let now = Date()
        for offset in [-30.0, 0.0] {
            let date = now.addingTimeInterval(offset)
            let charging = scenario == "charging"
            let connected = scenario != "battery"
            let current = charging ? 900 : -650
            let sample = BatterySample(date: date, percent: 65, temperature: old.temperature, externalPower: connected,
                charging: charging, currentMA: current, voltageMV: old.voltageMV, cycles: old.cycles, healthPercent: old.healthPercent)
            let telemetry = BatteryTelemetry(sensorDate: date, currentMA: current, remainingMAH: 2800, fullMAH: 4400,
                percent: 65, externalPower: connected, charging: charging)
            previewModel.acceptReading(sample: sample, telemetry: telemetry, now: date, uptime: 1000 + offset)
        }
    }
    if let sleep = ProcessInfo.processInfo.environment["BATTERY_SAVER_PREVIEW_SLEEP"], var status = previewModel.status {
        status.date = Date()
        status.sleepControlAvailable = true
        status.sleepHeld = sleep == "held"
        status.sleepMessage = status.sleepHeld ? "Keeping awake until \(status.settings.upper)%" : nil
        previewModel.status = status
    }
    if ProcessInfo.processInfo.environment["BATTERY_SAVER_PREVIEW_ERROR"] == "1" {
        previewModel.error = "Resume at must be below Limit at. Active settings have not changed."
    }
    // Complete deterministic fixtures keep screenshots independent of the installed helper.
    if let fixture = ProcessInfo.processInfo.environment["BATTERY_SAVER_PREVIEW_FIXTURE"] {
        let now = Date()
        var status = HelperStatus(state: "Paused until 75%", error: nil, settings: Settings(), sample: nil,
                                  backend: "Preview", chargingAllowed: false)
        status.sleepControlAvailable = true; status.dischargeSupported = fixture != "old"
        if fixture == "discharge" { status.dischargeTarget = 80 }
        if fixture == "calibration" { status.calibrationActive = true; status.state = "Calibration · discharging to 15%" }
        previewModel.status = fixture == "missing" ? nil : status
        for offset in [-10.0, 0.0] {
            let date = now.addingTimeInterval(offset)
            let percent = fixture == "discharge" ? 85 : 80
            let charging = fixture == "charging"
            let connected = fixture != "battery" && fixture != "discharge"
            let current = charging ? 700 : (fixture == "draining" || fixture == "discharge" ? -600 : 0)
            let sample = BatterySample(date: date, percent: percent, temperature: 26, externalPower: connected,
                                       charging: charging, currentMA: current, voltageMV: 12000, cycles: 433, healthPercent: 86)
            previewModel.acceptReading(sample: sample, telemetry: BatteryTelemetry(sensorDate: date, currentMA: current,
                remainingMAH: 3500, fullMAH: 4400, percent: percent, externalPower: connected, charging: charging), now: date, uptime: 1000 + offset)
        }
        if fixture == "error" { previewModel.error = "Resume at must be below Limit at. Active settings have not changed. This is a longer warning to verify that the full three-line error remains visible without hiding the footer or controls." }
    }
    let quick = ProcessInfo.processInfo.environment["BATTERY_SAVER_PREVIEW_QUICK"] == "1"
    let view = NSHostingView(rootView: quick ? AnyView(QuickCard(model: previewModel, openDetails: {})) : AnyView(Panel(model: previewModel)))
    view.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["BATTERY_SAVER_PREVIEW_DARK"] == "1" ? .darkAqua : .aqua)
    view.frame = NSRect(x: 0, y: 0, width: 380, height: 720)
    view.layoutSubtreeIfNeeded()
    view.frame.size = view.fittingSize
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fputs("Cannot create preview bitmap.\n", stderr); exit(1) }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2])) }
    catch { fputs("Preview failed: \(error.localizedDescription)\n", stderr); exit(1) }
    print("Rendered preview without opening a window.")
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
