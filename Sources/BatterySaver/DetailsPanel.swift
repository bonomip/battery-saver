import AppKit
import SwiftUI
import BatteryCore

struct Panel: View {
    @ObservedObject var model: BatteryModel
    @State private var showCalibration = false
    @State private var showUninstall = false
    private let green = Color(NSColor.systemGreen)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                }.frame(maxWidth: .infinity)
            }
            HStack(spacing: 16) {
                Toggle("Start at login", isOn: Binding(get: { model.startAtLogin }, set: { model.setStartAtLogin($0) }))
                    .toggleStyle(.switch).fixedSize()
                Divider().frame(height: 28)
                Circle().fill(model.status?.isCurrent == true ? green : .gray).frame(width: 7, height: 7)
                Text(model.status?.isCurrent == true ? "Helper active" : "Helper needs attention").font(.caption)
                Spacer(minLength: 0)
                if model.helperInstalled {
                    Button("Manage helper…") { showUninstall = true }.disabled(model.saving)
                } else {
                    Button("Install helper…") { model.installHelper() }.disabled(model.saving)
                }
            }.padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
            actions
            HStack {
                Label("Runs quietly in your menu bar", systemImage: "leaf")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Quit app") { NSApp.terminate(nil) }
                    .help("The background helper keeps protecting your battery.")
            }
        }
        .padding(18)
        .frame(width: 680)
        .background(Color(NSColor.windowBackgroundColor))
        .accentColor(green)
        .controlSize(.regular)
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

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 23, weight: .medium)).foregroundColor(green)
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 13).fill(green.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Settings & details").font(.system(size: 22, weight: .semibold))
                Text("Charge limits, health and calibration.").font(.callout).foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private var overview: some View {
        card {
            HStack(alignment: .center, spacing: 18) {
                BatteryRing(model: model, size: 76)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.activity.title).font(.callout).fontWeight(.medium).lineLimit(2)
                    if let estimate = model.estimate {
                        Label(estimate, systemImage: "clock").font(.caption).foregroundColor(.secondary)
                            .help("Approximate: workload, current and charge taper can change the remaining time.")
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(model.sample.map { String(format: "%.1f°C", $0.temperature) } ?? "—")
                        .font(.title3).monospacedDigit()
                    Text("Temperature").font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private var protection: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Charge limits", systemImage: "battery.75").font(.headline)
                Toggle("Battery protection", isOn: model.draft(\.enabled))
                    .toggleStyle(.switch).font(.callout).disabled(!model.helperInstalled)
                Divider()
                ChargeThresholdControl(title: "Resume at", value: model.draft(\.lower), range: 20...99, inputErrors: $model.inputErrors)
                ChargeThresholdControl(title: "Limit at", value: model.draft(\.upper), range: 21...100, inputErrors: $model.inputErrors)
                Text("Pauses at \(Int(model.settings.heatPause))°C. Resumes after cooling to \(Int(model.settings.heatResume))°C.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if let status = model.status, status.isCurrent, status.settings.enabled, status.state.hasPrefix("Cooling") {
                    Text("Charging paused while the battery cools.").font(.caption).foregroundColor(.orange)
                }
                Divider()
                sleepBehavior
            }.disabled(model.saving)
        }
    }

    private var sleepBehavior: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Stay awake until charge limit", isOn: model.draft(\.keepAwakeUntilLimit))
                    .disabled(model.status?.sleepControlAvailable != true || !model.helperInstalled || model.saving)
                    .font(.callout).toggleStyle(.switch)
                Text(model.status?.sleepControlAvailable == true
                     ? "Allows lid-closed charging; releases sleep at the limit or on unplug. The display can sleep."
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
                Label("Battery health", systemImage: "heart").font(.headline)
                HStack {
                    Text("Cycle count").foregroundColor(.secondary)
                    Spacer()
                    Text(model.sample?.cycles.map { "\($0)" } ?? "—").monospacedDigit()
                }.font(.callout)
                HStack {
                    Text("Raw capacity").foregroundColor(.secondary)
                    Spacer()
                    Text(model.sample?.healthPercent.map { String(format: "%.0f%%", $0) } ?? "—").monospacedDigit()
                    Image(systemName: "info.circle").foregroundColor(.secondary)
                }
                .font(.callout)
                .help("Raw full-charge capacity divided by design capacity. This estimate can differ from macOS Battery Health.")
            }
        }
    }

    private var calibration: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Calibration", systemImage: "gauge").font(.headline)
                if let status = model.status, status.isCurrent, status.calibrationActive {
                    Text(status.state).font(.caption).foregroundColor(green).fixedSize(horizontal: false, vertical: true)
                }
                Text("For inaccurate charge readings. Takes several hours and adds battery wear.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Calibrate…") { showCalibration = true }
                    .disabled(!model.protectionVerified || model.status?.calibrationActive == true || model.saving)
                if model.status?.isCurrent == true && model.status?.calibrationActive == true {
                    Button("Cancel calibration") { model.authorize(["--cancel-calibration"]) }
                        .disabled(model.saving)
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            Text(model.hasDraft ? "Unapplied changes" : "Settings up to date")
                .font(.caption).foregroundColor(model.hasDraft ? .orange : .secondary)
            Spacer()
            Button("Discard changes") { model.discardChanges() }
                .disabled((!model.hasDraft && model.inputErrors.isEmpty) || model.saving || model.awaitingSettings)
            Button(model.saving ? "Applying…" : "Apply changes…") { model.save() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.helperInstalled || !model.hasDraft || model.saving || model.awaitingSettings)
        }.padding(.vertical, 6)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}
