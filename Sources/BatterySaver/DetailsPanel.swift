import AppKit
import SwiftUI
import BatteryCore

struct Panel: View {
    @ObservedObject var model: BatteryModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var showCalibration = false
    @State private var showUninstall = false
    @State private var showCapacity = false
    @State private var showLimitsInfo = false
    private var stateAccent: Color { model.palette.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = model.warning {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(AppPalette.warning)
                    Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if model.error != nil { Button { model.error = nil } label: {
                        Image(systemName: "xmark")
                    }.buttonStyle(.plain).accessibilityLabel("Dismiss error") }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(AppPalette.warning.opacity(0.12)))
            }
            overview
            HStack(alignment: .top, spacing: 12) {
                protection.id(model.draftResetID).frame(maxWidth: .infinity)
                GeometryReader { geometry in
                    VStack(spacing: 12) {
                        health.fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            calibration.frame(maxWidth: .infinity, maxHeight: .infinity)
                            discharge.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }.frame(maxHeight: .infinity)
                        helperAndStartup.fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }.frame(maxWidth: .infinity)
            }.fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 680)
        .background(Color(AppPalette.windowBackground))
        .accentColor(stateAccent)
        .controlSize(.regular)
        .buttonStyle(SecondaryActionStyle())
        .alert("Start battery calibration?", isPresented: $showCalibration) {
            Button("Cancel", role: .cancel) {}
            Button("Start calibration") { model.startCalibration() }
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
                    .modifier(SettingsRiddleEasterEgg(tint: stateAccent))
                Text("Charge limits, health and calibration.").font(.callout).foregroundColor(.secondary)
            }
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power.circle")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
                .buttonStyle(.plain)
                .foregroundColor(.primary)
                .accessibilityLabel("Quit Battery Saver")
                .help("Quit Battery Saver, restore normal charging, and stop the helper. Your settings are kept.")
        }
    }

    private var overview: some View {
        card {
            HStack(alignment: .center, spacing: 18) {
                BatteryRing(model: model, size: 68)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.activity.title).font(.callout).fontWeight(.medium).lineLimit(2)
                    if let target = model.status?.dischargeTarget { Text("Discharging to \(target)%").font(.caption).foregroundColor(stateAccent) }
                    if let status = model.status, status.isCurrent, status.state.hasPrefix("Cooling") {
                        Text("Charging paused while the battery cools.").font(.caption).foregroundColor(AppPalette.warning)
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
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Text("Charge limits").font(.headline)
                    Button { showLimitsInfo.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                        .accessibilityLabel("About charge limits")
                        .popover(isPresented: $showLimitsInfo) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Charge limits").font(.headline)
                                Text("Charging pauses at your upper limit and restarts at the lower threshold. Between them, your Mac uses wall power while the battery drifts naturally. Turning limits off returns charging to macOS. Save changes to apply your choices.")
                                Text("Heat protection pauses charging at \(Int(model.settings.heatPause))°C and resumes at \(Int(model.settings.heatResume))°C.").foregroundColor(.secondary)
                            }.font(.callout).padding(16).frame(width: 300)
                        }
                    Spacer()
                    Toggle("Charge limits", isOn: model.draft(\.enabled))
                        .toggleStyle(StateSwitchStyle(tint: stateAccent, labelHidden: true))
                        .accessibilityLabel("Charge limits")
                        .disabled(model.saving || !model.helperCompatible)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ChargeThresholdControl(accent: stateAccent, title: "Resume at", value: model.draft(\.lower), range: 20...99, inputErrors: $model.inputErrors)
                    ChargeThresholdControl(accent: stateAccent, title: "Limit at", value: model.draft(\.upper), range: 21...100, inputErrors: $model.inputErrors)
                    Divider()
                    sleepBehavior
                }
                .disabled(!model.settings.enabled || model.saving || !model.helperCompatible)
                .opacity(model.settings.enabled ? 1 : 0.5)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.awaitingSettings ? "Waiting for helper confirmation…" : (model.hasDraft ? "Unsaved changes" : "Changes apply when saved."))
                        .font(.caption).foregroundColor(.secondary)
                    HStack { Spacer(minLength: 0); actions }
                }
            }
        }
    }

    private var helperAndStartup: some View {
        card {
            HStack(spacing: 16) {
                Toggle("Start at login", isOn: Binding(get: { model.startAtLogin }, set: { model.setStartAtLogin($0) }))
                    .toggleStyle(StateSwitchStyle(tint: stateAccent))
                    .font(.caption).frame(maxWidth: .infinity)
                HStack(spacing: 6) {
                    Circle().fill(model.helperCompatible && model.status?.isCurrent == true ? stateAccent : AppPalette.warning)
                        .frame(width: 6, height: 6)
                    Text("Helper").font(.caption)
                        .help(model.helperUpgrade.warning ?? (model.status?.isCurrent == true ? "Helper active" : "Helper needs attention"))
                    Spacer(minLength: 0)
                    if model.helperUpgrade == .updateRequired {
                        Button { model.updateHelper() } label: {
                            Image(systemName: "arrow.down.circle").frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain).accessibilityLabel("Update helper")
                        .help("Update the background helper").disabled(model.saving)
                    }
                    if model.helperInstalled {
                        Button { showUninstall = true } label: {
                            ToolbarIcon(symbol: "gearshape")
                        }
                        .buttonStyle(.plain).accessibilityLabel("Helper settings")
                        .help("Manage the background helper").disabled(model.saving)
                    } else {
                        Button("Install…") { model.installHelper() }.disabled(model.saving)
                    }
                }.frame(maxWidth: .infinity)
            }
            .overlay(Rectangle().fill(Color(NSColor.separatorColor))
                .frame(width: 1, height: 22).allowsHitTesting(false))
        }
    }

    private var discharge: some View {
        let target = model.status?.dischargeTarget
        let active = model.dischargeNeedsCancellation
        return Button {
            if active { model.cancelDischarge() } else { model.startDischarge() }
        } label: {
            operationLabel(title: active ? "Cancel discharge" : "Discharge to limit",
                detail: target.map { "Running from battery to \($0)%." } ?? (active ? "Adapter restoration needs attention." : "Use battery power down to your saved limit."),
                symbol: active ? "stop.circle" : "battery.50", active: active,
                iconImage: active ? nil : MenuBarBatteryIcon.image(
                    percent: model.sample?.percent, activity: .onBattery, tone: model.batteryTone,
                    appearance: NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!))
        }
        .buttonStyle(OperationTileStyle(tint: stateAccent))
        .help("Runs once to the saved limit. Cancels on sleep, heat, settings changes, after eight hours, or 30 minutes without progress. Keep the charger attached; adapter control can hide unplug detection.")
        .disabled(!model.canControlHelper || model.dischargePending || (!active && !model.canStartDischarge))
    }

    private var calibration: some View {
        Button {
            if model.calibrating { model.authorize(["--cancel-calibration"]) } else { showCalibration = true }
        } label: {
            operationLabel(title: model.calibrating ? "Cancel calibration" : "Calibrate",
                detail: model.calibrating ? (model.status?.state ?? "Calibration in progress") : "Recheck charge readings. Takes several hours.",
                symbol: model.calibrating ? "stop.circle" : "arrow.triangle.2.circlepath", active: model.calibrating)
        }
        .buttonStyle(OperationTileStyle(tint: stateAccent))
        .help("For inaccurate charge readings. Adds battery wear and does not restore lost capacity. Keep the lid open and charger connected.")
        .disabled(!model.canControlHelper || (!model.calibrating && !model.canStartCalibration))
    }

    private func operationLabel(title: String, detail: String, symbol: String, active: Bool, iconImage: NSImage? = nil) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Group {
                    if let iconImage = iconImage {
                        Image(nsImage: iconImage).renderingMode(.original)
                    } else {
                        Image(systemName: symbol).font(.system(size: 19, weight: .medium))
                            .foregroundColor(stateAccent)
                    }
                }
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(stateAccent.opacity(0.12)))
                Spacer()
                Image(systemName: active ? "xmark" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            }
            Text(title).font(.headline).lineLimit(2)
            Text(detail).font(.caption).foregroundColor(.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    private var sleepBehavior: some View {
        Group {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Stay awake until charge limit", isOn: model.draft(\.keepAwakeUntilLimit))
                    .disabled(model.status?.sleepControlAvailable != true || !model.helperInstalled || model.saving)
                    .font(.callout).toggleStyle(StateSwitchStyle(tint: stateAccent))
                Text(model.status?.sleepControlAvailable == true
                     ? "Allows lid-closed charging. Releases sleep at the limit or on unplug."
                     : "Update the helper to enable lid-closed charging.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    .help("Releases on heat/errors, after 8 hours, or after 30 minutes without charge progress. Restores only the system sleep setting acquired by this helper.")
                if let message = model.status?.sleepMessage {
                    Text(message).font(.caption).foregroundColor(model.status?.sleepHeld == true ? stateAccent : AppPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var health: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
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

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Discard changes") { model.discardChanges() }
                .disabled((!model.hasDraft && model.inputErrors.isEmpty) || model.saving || model.awaitingSettings)
            Button(model.saving ? "Applying…" : "Save changes…") { model.save() }
                .buttonStyle(StateActionStyle(tint: stateAccent))
                .disabled(!model.helperCompatible || !model.helperInstalled || !model.hasDraft || model.saving || model.awaitingSettings || model.dischargePending)
        }.fixedSize()
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .cardSurface(cornerRadius: 14)
            .shadow(color: .black.opacity(0.035), radius: 3, y: 2)
    }
}
