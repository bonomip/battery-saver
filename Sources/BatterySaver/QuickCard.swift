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
        switch model.activity {
        case .charging: return Color(red: 0.12, green: 0.61, blue: 0.43)
        case .pluggedIn: return Color(red: 0.16, green: 0.46, blue: 0.85)
        case .onBattery: return Color(red: 0.82, green: 0.62, blue: 0.08)
        case .unavailable: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(model.activity.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let warning = model.warning {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).help(warning)
                }
                Image(systemName: model.sample?.externalPower == true ? "bolt.fill" : "leaf.fill")
                    .font(.system(size: 14, weight: .medium)).foregroundColor(tint)
            }
            HStack(spacing: 24) {
                ZStack {
                    Circle().stroke(tint.opacity(0.12), lineWidth: 10)
                    Circle().trim(from: 0, to: CGFloat(model.sample?.percent ?? 0) / 100)
                        .stroke(AngularGradient(colors: [tint.opacity(0.5), tint], center: .center,
                                                startAngle: .degrees(0), endAngle: .degrees(360)),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text(model.sample.map { "\($0.percent)" } ?? "—")
                                .font(.system(size: 43, weight: .medium, design: .rounded)).monospacedDigit()
                            Text("%").font(.system(size: 18, weight: .medium)).foregroundColor(.secondary)
                        }
                        Text("BATTERY").font(.system(size: 9, weight: .semibold)).tracking(1.6).foregroundColor(.secondary)
                    }
                }.frame(width: 136, height: 136)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(model.sample.map { "Battery \($0.percent) percent" } ?? "Battery unavailable")
                VStack(alignment: .leading, spacing: 20) {
                    metric(model.sample.map { String(format: "%.1f°C", $0.temperature) } ?? "—", label: "Temperature")
                    metric(limit, label: "Charge limit")
                }
                Spacer(minLength: 0)
            }.padding(.vertical, 3)
                HStack {
                    Text("Settings & details").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                }.padding(.horizontal, 14).frame(height: 38)
                    .foregroundColor(colorScheme == .dark ? .black : .white)
                    .background(colorScheme == .dark ? Color.white.opacity(0.9) : Color(red: 0.13, green: 0.19, blue: 0.17))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(DetailsActionSurface(action: openDetails))
        }
        .padding(20).frame(width: 326, height: 280)
        .background(LinearGradient(colors: [tint.opacity(colorScheme == .dark ? 0.08 : 0.06), Color(NSColor.windowBackgroundColor)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 21, weight: .medium, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }
}
