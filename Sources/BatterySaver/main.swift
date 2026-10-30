import AppKit
import SwiftUI
import BatteryCore
import IOKit.ps

final class BatteryModel: ObservableObject {
    @Published var sample: BatterySample?
    @Published var status: HelperStatus?
    @Published var error: String?
    @Published private var settingsDraft = SettingsDraft()
    var settings: BatteryCore.Settings { settingsDraft.settings }
    @Published var saving = false
    @Published var inputErrors: Set<String> = []
    var hasDraft: Bool { settingsDraft.edited }
    var timer: Timer?
    private var powerSource: CFRunLoopSource?
    var onRefresh: (() -> Void)?
    var readError: String?
    var helperInstalled: Bool { FileManager.default.fileExists(atPath: Locations.helper) }
    var protectionVerified: Bool { helperInstalled && sample != nil && status?.isCurrent == true && status?.settings.enabled == true }
    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
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
    func refresh() {
        do { sample = try BatteryReader.read(); readError = nil } catch { sample = nil; readError = error.localizedDescription }
        status = (try? Data(contentsOf: URL(fileURLWithPath: Locations.status))).flatMap { try? JSONDecoder().decode(HelperStatus.self, from: $0) }
        if let message = settingsDraft.refresh(status: status) { error = message }
        if !FileManager.default.fileExists(atPath: Locations.helper) { settingsDraft.helperUnavailable() }
        onRefresh?()
    }
    var activity: BatteryActivity { BatteryActivity(sample: sample) }
    var state: String { activity.title }
    var warning: String? {
        if let error = error { return error }
        if let readError = readError { return readError }
        guard helperInstalled else { return nil }
        guard let status = status else { return "Waiting for the background helper. Protection is unverified." }
        if let error = status.error { return error }
        if !status.running { return "Background helper stopped. Protection is unverified." }
        if !status.isCurrent { return "Background helper is not responding. Protection is unverified." }
        return nil
    }
    func authorize(_ arguments: [String]) {
        runAuthorized(executable: Locations.helper, arguments: arguments)
    }
    func draft<Value>(_ keyPath: WritableKeyPath<BatteryCore.Settings, Value>) -> Binding<Value> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { self.settingsDraft.edit(keyPath, to: $0) })
    }
    func installHelper() {
        guard let script = Bundle.main.path(forResource: "install-helper", ofType: "sh") else { error = "Helper installer is missing from this app bundle."; return }
        runAuthorized(executable: "/bin/zsh", arguments: [script])
    }
    func removeHelper() {
        guard let script = Bundle.main.path(forResource: "uninstall-helper", ofType: "sh") else { error = "Helper uninstaller is missing from this app bundle."; return }
        runAuthorized(executable: "/bin/zsh", arguments: [script])
    }
    private func runAuthorized(executable: String, arguments: [String], configuration: Bool = false) {
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
                if configuration { self.settingsDraft.authorizationFinished(succeeded: message == nil && !cancelled, cancelled: cancelled) }
                self.refresh()
            }
        }
    }
    func save() {
        guard !saving else { return }
        guard inputErrors.isEmpty else { error = "Enter whole-number percentages in the allowed ranges before applying."; return }
        let submitted: BatteryCore.Settings
        do { submitted = try settingsDraft.beginApply() } catch { self.error = error.localizedDescription; return }
        runAuthorized(executable: Locations.helper, arguments: ["--configure", submitted.enabled ? "1" : "0", "\(submitted.lower)", "\(submitted.upper)", "\(submitted.heatPause)", "\(submitted.heatResume)"], configuration: true)
    }
}

struct ChargeThresholdControl: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    @Binding var inputErrors: Set<String>
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                TextField(title, text: $text)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 58)
                    .accessibilityLabel("\(title) percentage")
                Text("%")
            }
            Slider(value: Binding(get: { Double(value) }, set: {
                value = Int($0.rounded()); text = "\(value)"; inputErrors.remove(title)
            }), in: Double(range.lowerBound)...Double(range.upperBound))
                .accessibilityLabel(title)
            if inputErrors.contains(title) {
                Text("Enter a whole number from \(range.lowerBound) to \(range.upperBound)%.")
                    .font(.caption).foregroundColor(.red)
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    let menu = NSMenu()
    var settingsWindow: NSWindow?
    let model = BatteryModel()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
        // Native menu tracking owns menu-bar visibility, including fullscreen Spaces.
        menu.autoenablesItems = false
        menu.delegate = self
        let card = QuickCardHost(rootView: QuickCard(model: model) { [weak self] in
            self?.menu.cancelTracking()
            DispatchQueue.main.async { self?.openSettings() }
        })
        // Keep geometry fixed during tracking; the read-only card has no keyboard fields.
        card.frame = NSRect(x: 0, y: 0, width: 326, height: 280)
        let entry = NSMenuItem(title: "Settings & details", action: #selector(openSettings), keyEquivalent: "")
        entry.target = self; entry.view = card
        menu.addItem(entry)
        item.menu = menu
        model.onRefresh = { [weak self] in self?.update() }; update()
    }
    func update() {
        item.button?.title = model.sample.map { "\($0.percent)%" } ?? "—"
        item.button?.image = NSImage(systemSymbolName: model.protectionVerified ? "leaf.fill" : "battery.100", accessibilityDescription: "Battery Saver")
        item.button?.imagePosition = .imageLeading
        item.button?.toolTip = model.state
    }
    func menuWillOpen(_ menu: NSMenu) { model.refresh() }
    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Battery Saver Settings"
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.contentViewController = NSHostingController(rootView: Panel(model: model))
            window.center()
            settingsWindow = window
        }
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--verify-details-button") {
    app.setActivationPolicy(.prohibited)
    var actions = 0
    let host = QuickCardHost(rootView: QuickCard(model: BatteryModel()) { actions += 1 })
    host.frame = NSRect(x: 0, y: 0, width: 326, height: 280)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func findButton(_ view: NSView) -> DetailsActionButton? {
        if let button = view as? DetailsActionButton { return button }
        return view.subviews.compactMap { findButton($0) }.first
    }
    guard let button = findButton(host), button.bounds.width >= 280, button.bounds.height >= 38 else {
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
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--render-preview" {
    app.setActivationPolicy(.prohibited)
    let previewModel = BatteryModel()
    if let scenario = ProcessInfo.processInfo.environment["BATTERY_SAVER_PREVIEW_POWER"] {
        let old = previewModel.sample
        previewModel.sample = BatterySample(date: Date(), percent: old?.percent ?? 60, temperature: old?.temperature ?? 25,
            externalPower: scenario != "battery", charging: scenario == "charging", currentMA: nil, voltageMV: nil,
            cycles: old?.cycles, healthPercent: old?.healthPercent)
    }
    if ProcessInfo.processInfo.environment["BATTERY_SAVER_PREVIEW_ERROR"] == "1" {
        previewModel.error = "Resume at must be below Limit at. Active settings have not changed."
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
