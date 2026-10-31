import SwiftUI
import QuartzCore

final class StatusEasterEggs: ObservableObject {
    static let auroraDuration: TimeInterval = 12
    static let boltDuration: TimeInterval = 3
    @Published var optionDown = false
    @Published var hovered = false
    @Published var aurora = false
    @Published var winkID = 0
    @Published var winking = false
    @Published var heartbeatID = 0
    @Published var heartbeatScale: CGFloat = 1
    @Published var heartVisible = false
    @Published var moonID = 0
    @Published var moonVisible = false
    @Published var boltID = 0
    private var titleTaps = 0
    private var lastTitleTap: TimeInterval = 0
    var auroraRequested: Bool { hovered && optionDown }

    func hoverChanged(_ inside: Bool) {
        optionDown = NSEvent.modifierFlags.contains(.option)
        hovered = inside
        if !inside { aurora = false }
    }
    func setOption(_ down: Bool) {
        optionDown = down
        if !down { aurora = false }
    }
    func temperatureTapped() {
        if Calendar.current.component(.hour, from: Date()) < 5 { moonID += 1 }
    }
    func titleTapped() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTitleTap > 2 || now < lastTitleTap { titleTaps = 0 }
        lastTitleTap = now
        titleTaps += 1
        if titleTaps == 7 { titleTaps = 0; boltID += 1 }
    }

}

struct StatusEasterEggLifecycle: ViewModifier {
    @ObservedObject var effects: StatusEasterEggs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
        .task(id: effects.auroraRequested) {
            effects.aurora = effects.auroraRequested
            guard effects.auroraRequested else { return }
            do { try await Task.sleep(nanoseconds: UInt64(StatusEasterEggs.auroraDuration * 1_000_000_000)) } catch { return }
            effects.aurora = false
        }
        .task(id: effects.winkID) {
            guard effects.winkID > 0 else { return }
            effects.winking = true
            do { try await Task.sleep(nanoseconds: 650_000_000) } catch { return }
            effects.winking = false
        }
        .task(id: effects.moonID) {
            guard effects.moonID > 0 else { return }
            effects.moonVisible = true
            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            effects.moonVisible = false
        }
        .task(id: effects.heartbeatID) {
            guard effects.heartbeatID > 0 else { return }
            effects.heartVisible = true
            if reduceMotion {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            } else {
                for _ in 0..<2 {
                    withAnimation(.easeInOut(duration: 0.55)) { effects.heartbeatScale = 1.055 }
                    do { try await Task.sleep(nanoseconds: 550_000_000) } catch { return }
                    withAnimation(.easeInOut(duration: 0.55)) { effects.heartbeatScale = 1 }
                    do { try await Task.sleep(nanoseconds: 550_000_000) } catch { return }
                }
                do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }
            }
            effects.heartVisible = false
        }
        .onDisappear {
            effects.aurora = false; effects.winking = false; effects.moonVisible = false
            effects.heartVisible = false; effects.heartbeatScale = 1
        }
    }
}

struct SecretChargeEasterEgg: ViewModifier {
    let effects: StatusEasterEggs
    func body(content: Content) -> some View {
        content.contentShape(Rectangle()).onTapGesture { effects.titleTapped() }
    }
}

struct BatteryRingEasterEgg: ViewModifier {
    @ObservedObject var effects: StatusEasterEggs
    let tint: Color
    func body(content: Content) -> some View {
        content
            .overlay { if effects.winking { WinkFace(tint: tint) } }
        .overlay(alignment: .bottomTrailing) {
            if effects.heartVisible { Image(systemName: "heart.fill").font(.caption).foregroundColor(tint) }
        }
        .scaleEffect(effects.heartbeatScale)
        .contentShape(Circle())
        .onTapGesture(count: 2) { effects.winkID += 1 }
        .simultaneousGesture(LongPressGesture(minimumDuration: 2, maximumDistance: 12)
            .onEnded { _ in effects.heartbeatID += 1 })
        .accessibilityAction(named: Text("Battery wink")) { effects.winkID += 1 }
        .accessibilityAction(named: Text("Tiny heartbeat")) { effects.heartbeatID += 1 }
    }
}

private struct WinkFace: View {
    let tint: Color
    var body: some View {
    VStack(spacing: 7) {
        HStack(spacing: 12) {
            Capsule().fill(tint).frame(width: 9, height: 2)
            Circle().fill(tint).frame(width: 4, height: 4)
        }
        Path { path in
            path.addArc(center: CGPoint(x: 12, y: 0), radius: 10,
                startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        }.stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round)).frame(width: 24, height: 10)
    }
    }
}

struct NightShiftEasterEgg: ViewModifier {
    @ObservedObject var effects: StatusEasterEggs
    let tint: Color
    func body(content: Content) -> some View {
        Button { effects.temperatureTapped() } label: {
            content.overlay(alignment: .topTrailing) {
                if effects.moonVisible {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 32, weight: .medium))
                        .foregroundColor(tint).padding(8).accessibilityHidden(true)
                }
            }
        }.buttonStyle(.plain).frame(maxWidth: .infinity)
    }
}

final class NativeStatusEasterEggs {
    private let boltLayer = CAShapeLayer()
    private var lastBoltID = 0
    private var auroraRunning = false
    private var flagsMonitor: Any?
    private weak var borderGradient: CAGradientLayer?
    private weak var surface: CALayer?
    var optionChanged: ((Bool) -> Void)?

    func layout(in layer: CALayer, borderGradient: CAGradientLayer) {
        self.surface = layer
        self.borderGradient = borderGradient
        if boltLayer.superlayer !== layer {
        boltLayer.zPosition = 1001
        boltLayer.opacity = 0
        let bolt = CGMutablePath()
        bolt.move(to: CGPoint(x: 2, y: -7))
        for point in [CGPoint(x: -4, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: -2, y: 7),
                      CGPoint(x: 5, y: -2), CGPoint(x: 1, y: -2)] { bolt.addLine(to: point) }
        bolt.closeSubpath()
        boltLayer.path = bolt
        boltLayer.fillColor = NSColor.white.cgColor
        boltLayer.shadowColor = NSColor.white.cgColor
        boltLayer.shadowOpacity = 0.7
        boltLayer.shadowRadius = 3
        boltLayer.shadowOffset = .zero
        layer.addSublayer(boltLayer)
        }
        boltLayer.contentsScale = layer.contentsScale
    }

    func windowChanged(_ window: NSWindow?) {
        if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor); flagsMonitor = nil }
        if let window = window {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self, weak window] event in
                guard let self = self, let window = window else { return event }
                if event.window === window || NSApp.keyWindow === window {
                    self.optionChanged?(event.modifierFlags.contains(.option))
                }
                return event
            }
        } else {
            borderGradient?.removeAllAnimations()
            boltLayer.removeAllAnimations()
            optionChanged = nil
        }
    }
    deinit {
        if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor) }
    }

    func update(aurora: Bool, boltID: Int, reduceMotion: Bool) {
        guard let borderGradient = borderGradient, let surface = surface else { return }
        let bounds = surface.bounds
        let shouldFlow = aurora && !reduceMotion
        if shouldFlow != auroraRunning {
            auroraRunning = shouldFlow
            borderGradient.removeAnimation(forKey: "aurora")
            if shouldFlow {
                let origin = borderGradient.startPoint
                let angle = atan2(origin.y - 0.5, origin.x - 0.5)
                let radius = hypot(origin.x - 0.5, origin.y - 0.5)
                let points = (0...16).map { step -> NSValue in
                    let theta = angle + CGFloat(step) * .pi / 8
                    return NSValue(point: CGPoint(x: 0.5 + cos(theta) * radius, y: 0.5 + sin(theta) * radius))
                }
                let start = CAKeyframeAnimation(keyPath: "startPoint")
                start.values = points
                start.duration = StatusEasterEggs.auroraDuration
                let end = CAKeyframeAnimation(keyPath: "endPoint")
                end.values = points.map { value in NSValue(point: CGPoint(x: 1 - value.pointValue.x, y: 1 - value.pointValue.y)) }
                end.duration = StatusEasterEggs.auroraDuration
                let group = CAAnimationGroup()
                group.animations = [start, end]
                group.duration = StatusEasterEggs.auroraDuration
                borderGradient.add(group, forKey: "aurora")
            }
        }
        guard boltID > 0, boltID != lastBoltID else { return }
        lastBoltID = boltID
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 1, 1, 0]
        opacity.keyTimes = [0, 0.08, 0.9, 1]
        opacity.duration = StatusEasterEggs.boltDuration
        let group = CAAnimationGroup()
        if reduceMotion {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            boltLayer.position = CGPoint(x: bounds.midX, y: 5)
            CATransaction.commit()
            group.animations = [opacity]
        } else {
            let motion = CAKeyframeAnimation(keyPath: "position")
            motion.path = CGPath(roundedRect: bounds.insetBy(dx: 5, dy: 5), cornerWidth: QuickCard.cornerRadius - 5,
                cornerHeight: QuickCard.cornerRadius - 5, transform: nil)
            motion.calculationMode = .paced
            motion.rotationMode = .rotateAuto
            motion.duration = StatusEasterEggs.boltDuration
            group.animations = [motion, opacity]
        }
        group.duration = StatusEasterEggs.boltDuration
        boltLayer.add(group, forKey: "secretCharge")
    }
}
