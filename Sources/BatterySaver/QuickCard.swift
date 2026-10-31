import SwiftUI
import BatteryCore
import QuartzCore

/// A native full-area hit target also accepts the first click in a non-key menu window.
final class DetailsActionButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class QuickCardHost: NSHostingView<QuickCard> {
    private let borderGradient = CAGradientLayer()
    private let borderMask = CAShapeLayer()
    let easterEggs = NativeStatusEasterEggs()
    override func layout() {
        super.layout()
        updateCornerLayer()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateCornerLayer()
        easterEggs.windowChanged(window)
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateCornerLayer()
    }
    private func updateCornerLayer() {
        // Native window framing owns clipping; these layers draw Easter egg overlays only.
        wantsLayer = true
        layer?.borderWidth = 0
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.allowsEdgeAntialiasing = true
        guard let layer = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if borderGradient.superlayer !== layer {
            borderGradient.zPosition = 1000
            borderGradient.mask = borderMask
            borderGradient.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
            layer.addSublayer(borderGradient)

        }
        borderGradient.frame = bounds
        borderGradient.contentsScale = layer.contentsScale
        borderMask.frame = borderGradient.bounds
        borderMask.contentsScale = layer.contentsScale
        easterEggs.layout(in: layer, borderGradient: borderGradient)
        borderMask.fillColor = NSColor.clear.cgColor
        borderMask.strokeColor = NSColor.white.cgColor
        borderMask.lineWidth = 1
        borderMask.path = CGPath(roundedRect: borderMask.bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: QuickCard.cornerRadius - 0.5, cornerHeight: QuickCard.cornerRadius - 0.5, transform: nil)
        CATransaction.commit()
    }
    func setBorder(colors: [NSColor], hovered: Bool, variant: Int, animated: Bool) {
        let target = colors.map { $0.cgColor }
        let directions = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 0.5),
                          CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 0.5)]
        let start = hovered ? directions[variant % directions.count] : CGPoint(x: 0, y: 0)
        let end = hovered ? directions[(variant + 4) % directions.count] : CGPoint(x: 1, y: 1)
        if !animated { borderGradient.removeAllAnimations() }
        guard (borderGradient.colors as? [CGColor]) != target || borderGradient.startPoint != start || borderGradient.endPoint != end else { return }
        let presentation = borderGradient.presentation() ?? borderGradient
        let previousColors = presentation.colors
        let previousStart = presentation.startPoint
        let previousEnd = presentation.endPoint
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderGradient.colors = target
        borderGradient.startPoint = start
        borderGradient.endPoint = end
        CATransaction.commit()
        borderGradient.removeAnimation(forKey: "statusBorderHover")
        if animated {
            let colors = CABasicAnimation(keyPath: "colors")
            colors.fromValue = previousColors; colors.toValue = target
            colors.duration = 0.22
            let startPoint = CABasicAnimation(keyPath: "startPoint")
            startPoint.fromValue = NSValue(point: previousStart); startPoint.toValue = NSValue(point: start)
            startPoint.duration = 0.22
            let endPoint = CABasicAnimation(keyPath: "endPoint")
            endPoint.fromValue = NSValue(point: previousEnd); endPoint.toValue = NSValue(point: end)
            endPoint.duration = 0.22
            let group = CAAnimationGroup()
            group.animations = [colors, startPoint, endPoint]
            group.duration = 0.22
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            borderGradient.add(group, forKey: "statusBorderHover")
        }
    }
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
    static let width: CGFloat = 374
    static let height: CGFloat = 250
    static let cornerRadius: CGFloat = 14
    let openDetails: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var borderVariant = 0
    @StateObject private var easterEggs = StatusEasterEggs()

    private var limit: String {
        guard let status = model.status, status.isCurrent else { return model.helperInstalled ? "—" : "Off" }
        guard status.settings.enabled else { return "Off" }
        return "\(status.settings.upper)%"
    }
    private var accent: NSColor {
        model.palette.nativeAccent
    }
    private var tint: Color { Color(accent) }
    private var badgeTextColor: Color {
        Color(AppPalette.foreground(on: accent,
            appearance: NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!))
    }
    private var borderColors: [NSColor] {
        guard easterEggs.aurora && easterEggs.auroraRequested else { return [.clear, .clear, .clear] }
        return [accent.withAlphaComponent(0.2), accent, accent.withAlphaComponent(0.2)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Battery Saver").font(.system(size: 13, weight: .semibold))
                    .modifier(SecretChargeEasterEgg(effects: easterEggs))
                Spacer()
                Image(systemName: "gearshape").font(.system(size: 16, weight: .medium))
                    .frame(width: 30, height: 30)
                    .overlay(DetailsActionSurface(action: openDetails))
                    .help("Settings and details")
                if let warning = model.warning {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(AppPalette.warning).help(warning)
                }
            }
            HStack(spacing: 18) {
                BatteryRing(model: model, size: 104, showsReading: !easterEggs.winking,
                    track: Color.primary.opacity(0.1))
                    .modifier(BatteryRingEasterEgg(effects: easterEggs, tint: tint))
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.activity.title).font(.system(size: 12, weight: .semibold))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .foregroundColor(badgeTextColor)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(tint))
                    Text(model.status?.dischargeTarget.map { "Discharging to \($0)%" } ?? model.estimate ?? pausedDetail).font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(AppPalette.surface)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
            HStack(spacing: 10) {
                metric(model.sample.map { String(format: "%.1f°C", $0.temperature) } ?? "—", label: "Temperature", symbol: "thermometer")
                    .modifier(NightShiftEasterEgg(effects: easterEggs, tint: tint))
                metric(limit, label: "Charge limit", symbol: "battery.75")
            }

        }
        .padding(.horizontal, 18).padding(.vertical, 6)
        .frame(width: Self.width, height: Self.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(AppPalette.windowBackground))
        .background(StatusMaterial(borderColors: borderColors, hovered: hovered, variant: borderVariant,
            animated: !reduceMotion, easterEggs: easterEggs,
            aurora: easterEggs.aurora && easterEggs.auroraRequested, boltID: easterEggs.boltID))
        .onHover { inside in
            if inside && !hovered { borderVariant = (borderVariant + Int.random(in: 1...7)) % 8 }
            easterEggs.hoverChanged(inside)
            hovered = inside
        }
        .modifier(StatusEasterEggLifecycle(effects: easterEggs))
        .ignoresSafeArea()

    }

    private var pausedDetail: String {
        guard let status = model.status, status.isCurrent, status.settings.enabled,
              status.chargingAllowed == false, status.state.hasPrefix("Paused") else { return "" }
        return "Resumes at \(status.settings.lower)%"
    }

    private func metric(_ value: String, label: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 20, weight: .regular))
                .foregroundColor(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 11)).foregroundColor(.secondary)
                Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(AppPalette.surface)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

struct BatteryRing: View {
    @ObservedObject var model: BatteryModel
    let size: CGFloat
    var showsReading = true
    var track: Color? = nil
    private var tint: Color { model.palette.accent }
    var body: some View {
        ZStack {
            Circle().stroke(track ?? tint.opacity(0.13), lineWidth: size * 0.075)
            Circle().trim(from: 0, to: CGFloat(min(100, max(0, model.sample?.percent ?? 0))) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsReading {
                Text(model.sample.map { "\($0.percent)%" } ?? "—")
                    .font(.system(size: size * 0.25, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }.padding(size * 0.05).frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.sample.map { "Battery \($0.percent) percent" } ?? "Battery unavailable")
    }
}

private struct StatusMaterial: NSViewRepresentable {
    let borderColors: [NSColor]
    let hovered: Bool
    let variant: Int
    let animated: Bool
    let easterEggs: StatusEasterEggs
    // Explicit trigger values invalidate the bridge immediately, independently of hover changes.
    let aurora: Bool
    let boltID: Int
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        guard let host = view.window?.contentView as? QuickCardHost else { return }
        host.easterEggs.optionChanged = { [weak effects = easterEggs] in effects?.setOption($0) }
        host.setBorder(colors: borderColors, hovered: hovered, variant: variant, animated: animated)
        host.easterEggs.update(aurora: aurora, boltID: boltID, reduceMotion: !animated)
    }
}
