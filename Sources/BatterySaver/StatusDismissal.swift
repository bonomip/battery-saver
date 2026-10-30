import AppKit

/// Monitors exist only while the status surface is visible.
final class StatusDismissal {
    private var local: Any?
    private var global: Any?
    private var observers: [NSObjectProtocol] = []
    private var spaceObserver: NSObjectProtocol?
    private var visibilityTimer: Timer?
    private var sawVisibleMenuBar = false

    func checkMenuBar(menuVisible: Bool, anchorVisible: Bool, close: () -> Void) {
        // Some fullscreen transitions initially report hidden before revealing.
        // Only treat the menu flag as dismissal after observing it visible.
        if menuVisible { sawVisibleMenuBar = true }
        if !anchorVisible || (sawVisibleMenuBar && !menuVisible) { close() }
    }

    static func shouldClose(type: NSEvent.EventType, keyCode: UInt16, inside: Bool) -> Bool {
        if type == .keyDown { return keyCode == 53 }
        return [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) && !inside
    }
    func start(contains: @escaping (NSEvent) -> Bool, anchorVisible: (() -> Bool)? = nil, close: @escaping () -> Void) {
        stop()
        sawVisibleMenuBar = NSMenu.menuBarVisible()
        if let anchorVisible = anchorVisible {
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.checkMenuBar(menuVisible: NSMenu.menuBarVisible(), anchorVisible: anchorVisible(), close: close)
            }
            timer.tolerance = 0.05
            visibilityTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { event in
            let dismiss = Self.shouldClose(type: event.type, keyCode: event.type == .keyDown ? event.keyCode : 0, inside: contains(event))
            if dismiss { close() }
            return dismiss && event.type == .keyDown ? nil : event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in close() }
        observers = [NSApplication.didResignActiveNotification, NSApplication.didHideNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: NSApp, queue: .main) { _ in close() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in close() }
    }
    func stop() {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        sawVisibleMenuBar = false
        if let local = local { NSEvent.removeMonitor(local) }
        if let global = global { NSEvent.removeMonitor(global) }
        local = nil; global = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let observer = spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        spaceObserver = nil
    }
    deinit { stop() }
}
