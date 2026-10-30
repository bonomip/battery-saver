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
                protection.frame(maxWidth: .infinity)
                VStack(spacing: 14) {
                    health
                    calibration
                }.frame(maxWidth: .infinity)
            }
            service
            HStack {
                Label("Runs quietly in your menu bar", systemImage: "leaf")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Quit app") { NSApp.terminate(nil) }
                    .help("The background helper keeps protecting your battery.")
            }
        }
        .padding(18)
        .frame(width: 600)
        .background(Color(NSColor.windowBackgroundColor))
        .accentColor(green)
        .controlSize(.small)
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
                Text(model.sample.map { "\($0.percent)%" } ?? "—")
                    .font(.system(size: 44, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text(model.activity.title).font(.callout).fontWeight(.medium).lineLimit(2)
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
                HStack {
                    Text(model.hasDraft ? "Unapplied changes" : "Settings up to date")
                        .font(.caption).foregroundColor(model.hasDraft ? .orange : .secondary)
                    Spacer(minLength: 0)
                }
                Button(model.saving ? "Applying…" : "Apply settings…") { model.save() }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    .disabled(!model.helperInstalled)
            }.disabled(model.saving)
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
                Button("Cancel calibration") { model.authorize(["--cancel-calibration"]) }
                    .font(.caption)
                    .disabled(model.status?.isCurrent != true || model.status?.calibrationActive != true || model.saving)
            }
        }
    }

    private var service: some View {
        HStack(spacing: 10) {
            Image(systemName: model.helperInstalled ? "checkmark.shield" : "shield")
                .foregroundColor(model.helperInstalled ? green : .secondary).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.helperInstalled ? "Background helper installed" : "Enable battery protection")
                    .font(.callout).fontWeight(.medium)
                Text(model.helperInstalled ? "The helper keeps running when you quit this app." : "Install helper with administrator approval.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            if model.helperInstalled {
                Button("Remove…") { showUninstall = true }
                    .help("Restore normal charging and remove the background helper.")
                    .disabled(model.saving)
            } else {
                Button("Install helper…") { model.installHelper() }.disabled(model.saving)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(green.opacity(0.07)))
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}
