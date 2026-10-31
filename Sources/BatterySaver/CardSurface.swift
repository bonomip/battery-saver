import SwiftUI

extension View {
    /// Shared Settings/status card material. Spacing stays with each layout.
    func cardSurface(cornerRadius: CGFloat = 10) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color(AppPalette.surface)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

struct ToolbarIcon: View {
    let symbol: String
    var size: CGFloat = 16
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .medium))
            .frame(width: 30, height: 30)
    }
}
