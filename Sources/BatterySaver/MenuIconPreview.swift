import AppKit
import BatteryCore

/// Offscreen visual verification; never registers startup or opens a window.
func renderMenuIconPreview(to url: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 960, pixelsHigh: 640,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = NSAffineTransform(); scale.scale(by: 2); scale.concat()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 480, height: 320).fill()
    let cases: [(String, Int?, BatteryActivity)] = [
        ("Charging", 73, .charging), ("Plugged in", 73, .pluggedIn), ("On battery", 73, .onBattery),
        ("Below 45%", 44, .onBattery), ("Adapter draining", 73, .pluggedInDraining),
        ("Low, charging", 15, .charging), ("Below 15%", 14, .onBattery), ("Unavailable", nil, .unavailable)]
    for (index, entry) in cases.enumerated() {
        let y = CGFloat(280 - index * 34)
        (entry.0 as NSString).draw(at: NSPoint(x: 14, y: y + 3), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
        for dark in [false, true] {
            let x: CGFloat = dark ? 330 : 180
            (dark ? NSColor.darkGray : NSColor(white: 0.94, alpha: 1)).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y - 2, width: 130, height: 26), xRadius: 5, yRadius: 5).fill()
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            MenuBarBatteryIcon.image(percent: entry.1, activity: entry.2, tone: entry.2.tone(percent: entry.1), appearance: appearance)
                .draw(in: NSRect(x: x + 10, y: y + 2, width: 28, height: 18))

        }
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SaverError("Could not render menu icons.") }
    try png.write(to: url)
}
