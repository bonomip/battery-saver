import AppKit
import BatteryCore

/// A static icon-only status-item glyph; the fill conveys the battery level.
enum MenuBarBatteryIcon {
    static func image(percent: Int?, activity: BatteryActivity, tone: BatteryTone, appearance: NSAppearance) -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 18), flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                let outline = color(tone)
                let body = NSBezierPath(roundedRect: NSRect(x: 1, y: 3.5, width: 23, height: 11),
                                        xRadius: 2.5, yRadius: 2.5)
                outline.setStroke()
                body.lineWidth = 1
                body.stroke()
                outline.setFill()
                NSBezierPath(roundedRect: NSRect(x: 25, y: 7, width: 2, height: 4),
                             xRadius: 0.8, yRadius: 0.8).fill()

                if let percent = percent {
                    let fraction = CGFloat(min(100, max(0, percent))) / 100
                    if fraction > 0 {
                        let interior = NSRect(x: 3, y: 5.5, width: 19, height: 7)
                        NSGraphicsContext.saveGraphicsState()
                        NSBezierPath(roundedRect: interior, xRadius: 1, yRadius: 1).addClip()
                        color(tone).setFill()
                        NSRect(x: interior.minX, y: interior.minY,
                               width: interior.width * fraction, height: interior.height).fill()
                        NSGraphicsContext.restoreGraphicsState()
                    }
                } else {
                    outline.setFill()
                    NSBezierPath(roundedRect: NSRect(x: 9.5, y: 8.5, width: 6, height: 1),
                                 xRadius: 0.5, yRadius: 0.5).fill()
                }

                if activity.isCharging {
                    let bolt = NSBezierPath()
                    bolt.move(to: NSPoint(x: 14, y: 15))
                    bolt.line(to: NSPoint(x: 9, y: 8))
                    bolt.line(to: NSPoint(x: 12, y: 8))
                    bolt.line(to: NSPoint(x: 11, y: 3))
                    bolt.line(to: NSPoint(x: 17, y: 10))
                    bolt.line(to: NSPoint(x: 13.5, y: 10))
                    bolt.close()
                    NSColor.windowBackgroundColor.setStroke()
                    bolt.lineWidth = 1.5
                    bolt.lineJoinStyle = .round
                    bolt.stroke()
                    outline.setFill()
                    bolt.fill()
                }
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = percent.map { "Battery \(min(100, max(0, $0))) percent" } ?? "Battery level unavailable"
        return image
    }

    static func color(_ tone: BatteryTone) -> NSColor {
        switch tone {
        case .green: return NSColor(srgbRed: 0.12, green: 0.61, blue: 0.43, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.16, green: 0.46, blue: 0.85, alpha: 1)
        case .yellow: return NSColor(srgbRed: 0.82, green: 0.62, blue: 0.08, alpha: 1)
        case .red: return .systemRed
        case .neutral: return .labelColor
        case .gray: return .systemGray
        }
    }
}
