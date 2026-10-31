import SwiftUI

struct ChargeThresholdControl: View {
    let accent: Color
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    @Binding var inputErrors: Set<String>
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).frame(width: 68, alignment: .leading)
                Slider(value: Binding(get: { Double(value) }, set: {
                    value = Int($0.rounded()); text = "\(value)"; inputErrors.remove(title)
                }), in: Double(range.lowerBound)...Double(range.upperBound))
                    .accentColor(accent).tint(accent)
                    .accessibilityLabel(title)
                TextField(title, text: $text)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 48)
                    .accessibilityLabel("\(title) percentage")
                Text("%")
            }.padding(.vertical, 3)
            if inputErrors.contains(title) {
                Text("Enter a whole number from \(range.lowerBound) to \(range.upperBound)%.")
                    .font(.caption).foregroundColor(AppPalette.error)
            }
        }
        .onAppear { text = "\(value)" }
        .onChange(of: text) { updated in
            if let number = Int(updated), range.contains(number) {
                inputErrors.remove(title)
                if value != number { value = number }
            } else { inputErrors.insert(title) }
        }
        .onChange(of: value) { updated in
            text = "\(updated)"; inputErrors.remove(title)
        }
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
