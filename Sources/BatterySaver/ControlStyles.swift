import SwiftUI

struct OperationTileStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.primary)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LinearGradient(
                colors: [tint.opacity(enabled && configuration.isPressed ? 0.18 : (enabled && hovered ? 0.12 : 0.05)), tint.opacity(0.015)],
                startPoint: .topLeading, endPoint: .bottomTrailing)))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(AppPalette.surface)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                enabled && hovered ? tint.opacity(0.4) : Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07), lineWidth: 1))
            .shadow(color: .black.opacity(enabled ? 0.04 : 0.015), radius: configuration.isPressed ? 1 : 4, y: configuration.isPressed ? 0 : 2)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(enabled ? 1 : 0.55)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

/// A button-backed switch keeps state coloring consistent on macOS 12.
struct StateSwitchStyle: ToggleStyle {
    let tint: Color
    var labelHidden = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme

    /// Choose the higher-contrast endpoint using sRGB relative luminance.
    private func thumbColor(for track: Color) -> Color {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!
        return Color(AppPalette.foreground(on: NSColor(track), appearance: appearance))
    }
    func makeBody(configuration: Configuration) -> some View {
        let track = configuration.isOn ? tint : AppPalette.inactiveTrack
        return Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                if !labelHidden {
                    configuration.label
                    Spacer(minLength: 8)
                }
                Capsule().fill(track)
                    .overlay(Capsule().stroke(Color.primary.opacity(0.65), lineWidth: 1))
                    .frame(width: 34, height: 20)
                    .overlay(Circle().fill(thumbColor(for: track)).frame(width: 14, height: 14)
                        .offset(x: configuration.isOn ? 7 : -7))
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .opacity(enabled ? 1 : 0.45)
    }
}

struct StateActionStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundColor(.primary)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(enabled ? (configuration.isPressed ? 0.65 : 0.35) : 0.1)))
            .opacity(enabled ? 1 : 0.5)
    }
}

struct SecondaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            .opacity(enabled ? 1 : 0.4)
    }
}
