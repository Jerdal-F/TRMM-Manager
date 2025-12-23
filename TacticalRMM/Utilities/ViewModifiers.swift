import SwiftUI

extension View {
    func primaryButton() -> some View {
        buttonStyle(.borderedProminent)
            .tint(Color.cyan)
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: 14))
    }

    func secondaryButton() -> some View {
        buttonStyle(.bordered)
            .tint(Color.cyan.opacity(0.7))
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: 14))
    }

}
