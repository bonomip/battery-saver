import AppKit

/// Use the native window frame, matching Settings without showing title-bar controls.
final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

func statusPanelFrame(size: NSSize, anchor: NSRect, visibleFrame: NSRect) -> NSRect {
    let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
    let size = NSSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
    let x = min(max(anchor.midX - size.width / 2, bounds.minX), bounds.maxX - size.width)
    let y = min(max(anchor.minY - 8 - size.height, bounds.minY), bounds.maxY - size.height)
    return NSRect(origin: NSPoint(x: x, y: y), size: size)
}

func makeStatusPanel(content: NSView, anchor: NSRect, visibleFrame: NSRect) -> StatusPanel {
    let frame = statusPanelFrame(size: content.frame.size, anchor: anchor, visibleFrame: visibleFrame)
    let panel = StatusPanel(contentRect: frame,
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovable = false
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        panel.standardWindowButton(button)?.isHidden = true
    }
    panel.backgroundColor = AppPalette.windowBackground
    panel.isOpaque = true
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isFloatingPanel = true
    panel.level = .popUpMenu
    panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
    panel.animationBehavior = .none
    panel.contentView = content
    // Installing a hosting view can resize a titled window to its intrinsic content size.
    // Apply the full popup frame afterward and fill it, including the hidden title bar.
    panel.setFrame(frame, display: false)
    content.autoresizingMask = [.width, .height]
    content.frame = NSRect(origin: .zero, size: frame.size)
    let scale = panel.backingScaleFactor
    panel.setFrameOrigin(NSPoint(x: (panel.frame.minX * scale).rounded() / scale,
                                 y: (panel.frame.minY * scale).rounded() / scale))
    return panel
}
