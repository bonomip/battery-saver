import AppKit

/// Keep the pointer halfway across and one quarter below the top, where screen edges allow.
func settingsWindowFrame(size: NSSize, pointer: NSPoint, visibleFrame: NSRect) -> NSRect {
    let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
    let size = NSSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
    let origin = NSPoint(x: min(max(pointer.x - size.width / 2, bounds.minX), bounds.maxX - size.width),
                         y: min(max(pointer.y - size.height * 0.75, bounds.minY), bounds.maxY - size.height))
    return NSRect(origin: origin, size: size)
}
