import SwiftUI

struct DarkGradientBackground: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.appBackground) private var backgroundStyle

    var body: some View {
        LinearGradient(
            colors: backgroundStyle.gradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .overlay {
            if let overlay = backgroundStyle.overlayGradient(accent: appTheme.accent) {
                overlay
                    .blur(radius: backgroundStyle.overlayBlurRadius)
            }
        }
    }
}
