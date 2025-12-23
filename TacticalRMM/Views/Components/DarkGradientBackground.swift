import SwiftUI

struct DarkGradientBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.07, blue: 0.12),
                Color(red: 0.02, green: 0.03, blue: 0.07)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .overlay(
            AngularGradient(
                colors: [
                    Color(red: 0.35, green: 0.55, blue: 0.90).opacity(0.18),
                    Color.clear,
                    Color(red: 0.35, green: 0.55, blue: 0.90).opacity(0.12),
                    Color.clear
                ],
                center: .center
            )
            .blur(radius: 160)
        )
    }
}
