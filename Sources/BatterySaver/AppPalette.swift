import AppKit
import SwiftUI
import BatteryCore

/// The sole battery-state color mapping, shared by SwiftUI and native drawing.
/// Controls vary opacity for interaction; they never substitute another state hue.
struct AppPalette {
    let tone: BatteryTone

    var nativeAccent: NSColor {
        switch tone {
        case .green: return NSColor(srgbRed: 0.12, green: 0.61, blue: 0.43, alpha: 1)
        case .blue: return NSColor(srgbRed: 0.16, green: 0.46, blue: 0.85, alpha: 1)
        case .yellow: return NSColor(srgbRed: 0.82, green: 0.62, blue: 0.08, alpha: 1)
        case .red: return .systemRed
        case .neutral: return .labelColor
        case .gray: return .systemGray
        }
    }
    var accent: Color { Color(nativeAccent) }

    static let windowBackground = NSColor.windowBackgroundColor
    static let surface = NSColor.controlBackgroundColor
    static let warning = Color(NSColor.systemOrange)
    static let error = Color(NSColor.systemRed)
    static let inactiveTrack = Color(white: 0.42)

    static func outline(appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    }

    /// Choose whichever of black and white has the higher sRGB contrast.
    static func foreground(on color: NSColor, appearance: NSAppearance) -> NSColor {
        var luminance = 0.0
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            func linear(_ value: CGFloat) -> Double {
                let x = Double(value)
                return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        return luminance > 0.179 ? .black : .white
    }
}
