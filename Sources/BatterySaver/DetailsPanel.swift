import AppKit
import SwiftUI
import BatteryCore

struct Panel: View {
    @ObservedObject var model: BatteryModel
    @State private var showCalibration = false
    @State private var showUninstall = false
    @State private var showCapacity = false
    private var green: Color { Color(MenuBarBatteryIcon.color(model.batteryTone)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let error = model.warning {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(error).font(.caption).lineLimit(3).help(error)
                    Spacer(minLength: 0)
                    if model.error != nil { Button { model.error = nil } label: {
                        Image(systemName: "xmark")
                    }.buttonStyle(.plain).accessibilityLabel("Dismiss error") }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
            }
            overview
            HStack(alignment: .top, spacing: 14) {
                protection.id(model.draftResetID).frame(maxWidth: .infinity)
                VStack(spacing: 14) {
                    health
                    calibration
                    discharge
                }.frame(maxWidth: .infinity)
            }
            card {
                HStack(spacing: 10) {
                    Toggle("Start at login", isOn: Binding(get: { model.startAtLogin }, set: { model.setStartAtLogin($0) }))
                        .toggleStyle(StateSwitchStyle(tint: green)).fixedSize()
                    Divider().frame(height: 26)
                    HStack(spacing: 6) {
                        Circle().fill(model.status?.isCurrent == true ? Color.green : .gray).frame(width: 6, height: 6)
                        Text("Helper").font(.caption)
                            .help(model.status?.isCurrent == true ? "Helper active" : "Helper needs attention")
                        if model.helperInstalled {
                            Button("Manage…") { showUninstall = true }.disabled(model.saving)
                        } else {
                            Button("Install…") { model.installHelper() }.disabled(model.saving)
                        }
                    }
                    Divider().frame(height: 26)
                    actions
                }.fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 680)
        .background(Color(NSColor.windowBackgroundColor))
        .accentColor(green)
        .controlSize(.regular)
        .buttonStyle(SecondaryActionStyle())
        .alert("Start battery calibration?", isPresented: $showCalibration) {
            Button("Cancel", role: .cancel) {}
            Button("Start calibration") { model.authorize(["--calibrate"]) }
        } message: {
            Text("Keep your Mac open and connected to power. It will discharge to 15%, charge to 100%, hold for one hour, then restore your limits. This can take several hours. Sleep, heat, a helper restart, or losing the charger during recharge cancels calibration. It does not restore lost battery capacity.")
        }
        .alert("Remove the background helper?", isPresented: $showUninstall) {
            Button("Cancel", role: .cancel) {}
            Button("Restore and remove", role: .destructive) { model.removeHelper() }
        } message: {
            Text("Battery Saver will restore normal charging and remove its background service. macOS will control charging afterward.")
        }
    }

    private var activeLimit: String {
        guard let status = model.status, status.isCurrent else { return "—" }
        return status.settings.enabled ? "\(status.settings.upper)%" : "Off"
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Settings & details").font(.system(size: 22, weight: .semibold))
                Text("Charge limits, health and calibration.").font(.callout).foregroundColor(.secondary)
            }
            Spacer()
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power").frame(width: 28, height: 28) }
                .accessibilityLabel("Quit Battery Saver")
                .help("Quit Battery Saver. The background helper keeps protecting your battery.")
        }
    }

    private var overview: some View {
        card {
            HStack(alignment: .center, spacing: 18) {
                BatteryRing(model: model, size: 68)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.activity.title).font(.callout).fontWeight(.medium).lineLimit(2)
                    if let target = model.status?.dischargeTarget { Text("Discharging to \(target)%").font(.caption).foregroundColor(.orange) }
                    if let status = model.status, status.isCurrent, status.state.hasPrefix("Cooling") {
                        Text("Charging paused while the battery cools.").font(.caption).foregroundColor(.orange)
                    }
                    if let estimate = model.estimate {
                        Label(estimate, systemImage: "clock").font(.caption).foregroundColor(.secondary)
                            .help("Approximate: workload, current and charge taper can change the remaining time.")
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(activeLimit).font(.title3).monospacedDigit()
                    Text("Charge limit").font(.caption).foregroundColor(.secondary)
                }
                VStack(alignment: .trailing, spacing: 5) {
                    Text(model.sample.map { String(format: "%.1f°C", $0.temperature) } ?? "—")
                        .font(.title3).monospacedDigit()
                    Text("Temperature").font(.caption).foregroundColor(.secondary)
                        .help("Charging pauses at \(Int(model.settings.heatPause))°C and resumes after cooling to \(Int(model.settings.heatResume))°C.")
                }
            }
        }
    }

    private var protection: some View {
        card {
            VStack(alignment: .leading, spacing: 4) {
                Text("Charge limits").font(.headline)
                Toggle("Battery protection", isOn: model.draft(\.enabled))
                    .toggleStyle(StateSwitchStyle(tint: green)).font(.callout).disabled(!model.helperInstalled)
                Text("Pause charging at your limit; resume only at the lower threshold.").font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                Group {
                ChargeThresholdControl(title: "Resume at", value: model.draft(\.lower), range: 20...99, inputErrors: $model.inputErrors)
                Text("Charging restarts at this percentage.").font(.caption).foregroundColor(.secondary)
                ChargeThresholdControl(title: "Limit at", value: model.draft(\.upper), range: 21...100, inputErrors: $model.inputErrors)
                Text("Charging stops at this percentage.").font(.caption).foregroundColor(.secondary)

                }
                Divider()
                sleepBehavior

            }.disabled(model.saving)
        }
    }

    private var discharge: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Discharge to limit").font(.headline)
                if let target = model.status?.dischargeTarget {
                    Text("Discharging to \(target)%").font(.caption).foregroundColor(.orange)
                    Button("Cancel discharge") { model.cancelDischarge() }.disabled(model.saving)
                } else {
                    Button("Discharge to limit…") { model.startDischarge() }
                        .help("Runs once to the applied limit. Cancels on sleep, heat, settings changes, after eight hours, or 30 minutes without progress. Adapter control can hide physical unplug detection; keep the cable attached.")
                        .disabled(model.sample?.externalPower != true || model.dischargePending || model.status?.dischargeSupported != true || !model.protectionVerified || model.hasDraft || model.awaitingSettings || model.saving || model.status?.calibrationActive == true || (model.sample?.percent ?? 0) <= (model.status?.settings.upper ?? 100))
                    Text(model.status?.dischargeSupported == true ? "Temporarily runs from battery until the applied limit. Sleep cancels it." : "Update the helper to enable discharge to limit.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var sleepBehavior: some View {
        Group {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Stay awake until charge limit", isOn: model.draft(\.keepAwakeUntilLimit))
                    .disabled(model.status?.sleepControlAvailable != true || !model.helperInstalled || model.saving)
                    .font(.callout).toggleStyle(StateSwitchStyle(tint: green))
                Text(model.status?.sleepControlAvailable == true
                     ? "Allows lid-closed charging. Releases sleep at the limit or on unplug."
                     : "Update the helper to enable lid-closed charging.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    .help("Releases on heat/errors, after 8 hours, or after 30 minutes without charge progress. Restores only the system sleep setting acquired by this helper.")
                if let message = model.status?.sleepMessage {
                    Text(message).font(.caption).foregroundColor(model.status?.sleepHeld == true ? green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var health: some View {
        card {
            VStack(alignment: .leading, spacing: 11) {
                Text("Battery health").font(.headline)
                HStack {
                    Text("Cycle count").foregroundColor(.secondary)
                    Spacer()
                    Text(model.sample?.cycles.map { "\($0)" } ?? "—").monospacedDigit()
                }.font(.callout)
                HStack {
                    Text("Raw capacity").foregroundColor(.secondary)
                    Button { showCapacity.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.plain).accessibilityLabel("About raw capacity")
                        .popover(isPresented: $showCapacity) {
                            Text("Raw full-charge capacity divided by design capacity. This estimate can differ from macOS Battery Health and does not indicate recoverable capacity.")
                                .padding(16).frame(width: 260)
                        }
                    Spacer()
                    Text(model.sample?.healthPercent.map { String(format: "%.0f%%", $0) } ?? "—").monospacedDigit()

                }
                .font(.callout)
                .help("Raw full-charge capacity divided by design capacity. This estimate can differ from macOS Battery Health.")
            }
        }
    }

    private var calibration: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Calibration").font(.headline)
                if let status = model.status, status.isCurrent, status.calibrationActive {
                    Text(status.state).font(.caption).foregroundColor(green).fixedSize(horizontal: false, vertical: true)
                }
                Text("For inaccurate charge readings. Takes several hours and adds battery wear.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Calibrate…") { showCalibration = true }
                    .disabled(!model.protectionVerified || model.status?.calibrationActive == true || model.status?.dischargeTarget != nil || model.saving)
                if model.status?.isCurrent == true && model.status?.calibrationActive == true {
                    Button("Cancel calibration") { model.authorize(["--cancel-calibration"]) }
                        .disabled(model.saving)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Discard changes") { model.discardChanges() }
                .disabled((!model.hasDraft && model.inputErrors.isEmpty) || model.saving || model.awaitingSettings)
            Button(model.saving ? "Applying…" : "Apply changes…") { model.save() }
                .buttonStyle(StateActionStyle(tint: green))
                .disabled(!model.helperInstalled || !model.hasDraft || model.saving || model.awaitingSettings || model.dischargePending)
        }.fixedSize()
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

/// A button-backed switch keeps state coloring consistent on macOS 12.
struct StateSwitchStyle: ToggleStyle {
    let tint: Color
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme

    /// Choose the higher-contrast endpoint using sRGB relative luminance.
    private func thumbColor(for track: Color) -> Color {
        var luminance = 0.0
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            if let rgb = NSColor(track).usingColorSpace(.sRGB) {
                func linear(_ value: CGFloat) -> Double {
                    let x = Double(value)
                    return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
                }
                luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
            }
        }
        return luminance > 0.179 ? .black : .white
    }
    func makeBody(configuration: Configuration) -> some View {
        let track = configuration.isOn ? tint : Color(white: 0.42)
        return Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                configuration.label
                Spacer(minLength: 8)
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
