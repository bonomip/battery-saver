import SwiftUI
import BatteryCore

/// A native full-area hit target also accepts the first click in a non-key menu window.
final class DetailsActionButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class QuickCardHost: NSHostingView<QuickCard> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func detailsButton(in view: NSView) -> DetailsActionButton? {
        if let button = view as? DetailsActionButton { return button }
        return view.subviews.compactMap { detailsButton(in: $0) }.first
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // SwiftUI's hosting wrappers can consume clicks in otherwise blank label space.
        // Route the complete visible rectangle directly to its native button.
        if let button = detailsButton(in: self), button.isEnabled, !button.isHidden {
            let local = convert(point, from: superview)
            if button.bounds.contains(button.convert(local, from: self)) { return button }
        }
        return super.hitTest(point)
    }
}

private struct DetailsActionSurface: NSViewRepresentable {
    let action: () -> Void
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> DetailsActionButton {
        let button = DetailsActionButton(title: "", target: context.coordinator, action: #selector(Coordinator.invoke))
        button.isBordered = false
        button.focusRingType = .none
        button.setAccessibilityLabel("Settings and details")
        return button
    }
    func updateNSView(_ button: DetailsActionButton, context: Context) { context.coordinator.action = action }
}

/// Read-only overview. Charge settings are edited only in the detailed window.
struct QuickCard: View {
    @ObservedObject var model: BatteryModel
    let openDetails: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var limit: String {
        guard let status = model.status, status.isCurrent else { return model.helperInstalled ? "—" : "Off" }
        guard status.settings.enabled else { return "Off" }
        return "\(status.settings.upper)%"
    }
    private var tint: Color {
        Color(MenuBarBatteryIcon.color(model.batteryTone))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "battery.75").foregroundColor(tint)
                Text("Battery Saver").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let warning = model.warning {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).help(warning)
                }
            }
            HStack(spacing: 18) {
                BatteryRing(model: model, size: 108)
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.activity.title).font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.12)))
                    Text(model.estimate ?? pausedDetail).font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                metric(model.sample.map { String(format: "%.1f°C", $0.temperature) } ?? "—", label: "Temperature")
                metric(limit, label: "Charge limit")
            }
                HStack {
                    Text("Settings & details").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                }.padding(.horizontal, 14).frame(height: 38)
                    .foregroundColor(colorScheme == .dark ? .black : .white)
                    .background(colorScheme == .dark ? Color.white.opacity(0.9) : Color(red: 0.04, green: 0.36, blue: 0.24))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(DetailsActionSurface(action: openDetails))
        }
        .padding(20).frame(width: 326, height: 312)
        .background(LinearGradient(colors: [tint.opacity(colorScheme == .dark ? 0.08 : 0.06), Color(NSColor.windowBackgroundColor)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var pausedDetail: String {
        guard let status = model.status, status.isCurrent, status.settings.enabled,
              status.chargingAllowed == false, status.state.hasPrefix("Paused") else { return "" }
        return "Resumes at \(status.settings.lower)%"
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor).opacity(0.7)))
    }
}

struct BatteryRing: View {
    @ObservedObject var model: BatteryModel
    let size: CGFloat
    private var tint: Color { Color(MenuBarBatteryIcon.color(model.batteryTone)) }
    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.13), lineWidth: size * 0.075)
            Circle().trim(from: 0, to: CGFloat(min(100, max(0, model.sample?.percent ?? 0))) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(model.sample.map { "\($0.percent)%" } ?? "—")
                .font(.system(size: size * 0.25, weight: .semibold, design: .rounded)).monospacedDigit()
        }.padding(size * 0.05).frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.sample.map { "Battery \($0.percent) percent" } ?? "Battery unavailable")
    }
}
