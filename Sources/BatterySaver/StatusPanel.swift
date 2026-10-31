import AppKit

/// A borderless surface lets QuickCard own its rounded background and single border.
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
    let panel = StatusPanel(contentRect: statusPanelFrame(size: content.frame.size, anchor: anchor, visibleFrame: visibleFrame),
                            styleMask: [.borderless], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isFloatingPanel = true
    panel.level = .popUpMenu
    panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
    panel.animationBehavior = .none
    panel.contentView = content
    let scale = panel.backingScaleFactor
    panel.setFrameOrigin(NSPoint(x: (panel.frame.minX * scale).rounded() / scale,
                                 y: (panel.frame.minY * scale).rounded() / scale))
    return panel
}
