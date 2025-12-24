import SwiftUI

private struct PrimaryButtonModifier: ViewModifier {
    @Environment(\.appTheme) private var appTheme

    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderedProminent)
            .tint(appTheme.accent)
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: 14))
    }
}

private struct SecondaryButtonModifier: ViewModifier {
    @Environment(\.appTheme) private var appTheme

    func body(content: Content) -> some View {
        content
            .buttonStyle(.bordered)
            .tint(appTheme.accent.opacity(0.75))
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: 14))
    }
}

extension View {
    func primaryButton() -> some View {
        modifier(PrimaryButtonModifier())
    }

    func secondaryButton() -> some View {
        modifier(SecondaryButtonModifier())
    }
}
