import AppKit
import SwiftUI
import BatteryCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var quitting = false
    var item: NSStatusItem!
    private var statusPanel: StatusPanel?
    private let statusDismissal = StatusDismissal()
    var settingsWindow: NSWindow?
    private var menuTracking = false
    private var closingStatus = false
    private var statusGeneration = UUID()
    private var lastIconKey: String?
    let model = BatteryModel()
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateLater }
        if model.saving {
            model.error = "Wait for the current helper operation to finish before quitting."
            return .terminateCancel
        }
        if !model.helperInstalled { model.helperSession.invalidate(); return .terminateNow }
        if model.helperRequiresLifecycleUpdate {
            let alert = NSAlert()
            alert.messageText = "Update the helper before quitting"
            alert.informativeText = "Update the installed helper so this app can manage its session safely. Your saved settings will be preserved."
            alert.addButton(withTitle: "Update helper")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { model.updateHelper() }
            return .terminateCancel
        }
        quitting = true
        model.helperSession.stop { [weak self] error in
            // AppKit must receive terminateLater before even an immediate stop reply.
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.quitting = false
                    self.model.error = error
                    let alert = NSAlert()
                    alert.messageText = "Helper shutdown could not be confirmed"
                    alert.informativeText = error + " Battery Saver will remain open."
                    alert.runModal()
                    sender.reply(toApplicationShouldTerminate: false)
                    self.model.checkHelperCompatibility()
                } else { sender.reply(toApplicationShouldTerminate: true) }
            }
        }
        return .terminateLater
    }
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
        if button.toolTip != model.activity.title { button.toolTip = model.activity.title }
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
