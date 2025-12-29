import Foundation
import SwiftUI
import UIKit

extension URLRequest {
    mutating func addDefaultHeaders(apiKey: String) {
        addValue("*/*", forHTTPHeaderField: "accept")
        addValue(apiKey, forHTTPHeaderField: "X-API-KEY")
    }
}

extension UIApplication {
    func dismissKeyboard() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

extension String {
    func ipv4Only() -> String {
        let ips = components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let ipv4s = ips.filter { !$0.contains(":") }
        return ipv4s.joined(separator: ", ")
    }

    func removingTrailingSlash() -> String {
        hasSuffix("/") ? String(dropLast()) : self
    }

    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var strippedScheme: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("https://") {
            return String(trimmed.dropFirst("https://".count))
        }
        if lower.hasPrefix("http://") {
            return String(trimmed.dropFirst("http://".count))
        }
        return trimmed
    }

    var isDemoEntry: Bool {
        strippedScheme.lowercased() == "demo"
    }

    var isValidDomainName: Bool {
        let trimmed = strippedScheme
        guard !trimmed.isEmpty else { return false }
        let pattern = "^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z]{2,63}$"
        return range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

extension View {
    @ViewBuilder
    func platformKeyboardType(_ type: UIKeyboardType) -> some View {
#if targetEnvironment(macCatalyst)
        self
#else
        self.keyboardType(type)
#endif
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case ocean
    case citrus
    case violet
    case sunset
    case mint
    case ember

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ocean: return "Ocean"
        case .citrus: return "Citrus"
        case .violet: return "Violet"
        case .sunset: return "Sunset"
        case .mint: return "Mint"
        case .ember: return "Ember"
        }
    }

    var accent: Color {
        switch self {
        case .ocean:
            return Color(red: 0.47, green: 0.69, blue: 0.96)
        case .citrus:
            return Color(red: 0.97, green: 0.69, blue: 0.28)
        case .violet:
            return Color(red: 0.72, green: 0.52, blue: 0.98)
        case .sunset:
            return Color(red: 0.98, green: 0.38, blue: 0.39)
        case .mint:
            return Color(red: 0.32, green: 0.78, blue: 0.63)
        case .ember:
            return Color(red: 0.95, green: 0.53, blue: 0.30)
        }
    }

    var accentSoft: Color {
        switch self {
        case .ocean:
            return Color(red: 0.33, green: 0.49, blue: 0.78)
        case .citrus:
            return Color(red: 0.82, green: 0.52, blue: 0.18)
        case .violet:
            return Color(red: 0.51, green: 0.36, blue: 0.77)
        case .sunset:
            return Color(red: 0.76, green: 0.22, blue: 0.30)
        case .mint:
            return Color(red: 0.22, green: 0.59, blue: 0.49)
        case .ember:
            return Color(red: 0.73, green: 0.34, blue: 0.17)
        }
    }
}

extension AppTheme {
    static let `default`: AppTheme = .ocean
}

enum AppBackgroundStyle: String, CaseIterable, Identifiable {
    case midnight
    case graphite
    case twilight
    case aurora
    case nebula
    case solstice
    case lagoon
    case emberGlow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .midnight: return "Midnight"
        case .graphite: return "Graphite"
        case .twilight: return "Twilight"
        case .aurora: return "Aurora"
        case .nebula: return "Nebula"
        case .solstice: return "Solstice"
        case .lagoon: return "Lagoon"
        case .emberGlow: return "Ember Glow"
        }
    }

    var gradientColors: [Color] {
        switch self {
        case .midnight:
            return [
                Color(red: 0.18, green: 0.20, blue: 0.38),
                Color(red: 0.04, green: 0.07, blue: 0.20)
            ]
        case .graphite:
            return [
                Color(red: 0.16, green: 0.16, blue: 0.18),
                Color(red: 0.03, green: 0.03, blue: 0.05)
            ]
        case .twilight:
            return [
                Color(red: 0.36, green: 0.14, blue: 0.58),
                Color(red: 0.12, green: 0.03, blue: 0.32)
            ]
        case .aurora:
            return [
                Color(red: 0.08, green: 0.30, blue: 0.35),
                Color(red: 0.02, green: 0.12, blue: 0.16)
            ]
        case .nebula:
            return [
                Color(red: 0.34, green: 0.08, blue: 0.70),
                Color(red: 0.14, green: 0.02, blue: 0.36)
            ]
        case .solstice:
            return [
                Color(red: 0.48, green: 0.16, blue: 0.14),
                Color(red: 0.16, green: 0.04, blue: 0.05)
            ]
        case .lagoon:
            return [
                Color(red: 0.12, green: 0.40, blue: 0.46),
                Color(red: 0.03, green: 0.16, blue: 0.24)
            ]
        case .emberGlow:
            return [
                Color(red: 0.58, green: 0.22, blue: 0.06),
                Color(red: 0.24, green: 0.06, blue: 0.02)
            ]
        }
    }

    var overlayBlurRadius: CGFloat { 200 }

    func overlayGradient(accent: Color) -> AngularGradient? {
        switch self {
        case .midnight:
            return AngularGradient(
                colors: [
                    accent.opacity(0.28),
                    .clear,
                    accent.opacity(0.20),
                    .clear
                ],
                center: .center
            )
        case .graphite:
            return AngularGradient(
                colors: [
                    Color.white.opacity(0.18),
                    .clear,
                    accent.opacity(0.16),
                    .clear
                ],
                center: .center
            )
        case .twilight:
            return AngularGradient(
                colors: [
                    Color(red: 0.72, green: 0.40, blue: 0.95).opacity(0.30),
                    .clear,
                    accent.opacity(0.22),
                    .clear
                ],
                center: .center
            )
        case .aurora:
            return AngularGradient(
                colors: [
                    Color(red: 0.20, green: 0.75, blue: 0.60).opacity(0.28),
                    .clear,
                    accent.opacity(0.20),
                    .clear
                ],
                center: .center
            )
        case .nebula:
            return AngularGradient(
                colors: [
                    Color(red: 0.52, green: 0.32, blue: 0.96).opacity(0.30),
                    .clear,
                    accent.opacity(0.20),
                    .clear
                ],
                center: .center
            )
        case .solstice:
            return AngularGradient(
                colors: [
                    Color(red: 0.98, green: 0.46, blue: 0.28).opacity(0.32),
                    .clear,
                    accent.opacity(0.22),
                    .clear
                ],
                center: .center
            )
        case .lagoon:
            return AngularGradient(
                colors: [
                    Color(red: 0.16, green: 0.78, blue: 0.74).opacity(0.30),
                    .clear,
                    accent.opacity(0.20),
                    .clear
                ],
                center: .center
            )
        case .emberGlow:
            return AngularGradient(
                colors: [
                    Color(red: 0.98, green: 0.52, blue: 0.24).opacity(0.34),
                    .clear,
                    accent.opacity(0.26),
                    .clear
                ],
                center: .center
            )
        }
    }
}

extension AppBackgroundStyle {
    static let `default`: AppBackgroundStyle = .midnight
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .default
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

private struct AppBackgroundKey: EnvironmentKey {
    static let defaultValue: AppBackgroundStyle = .default
}

extension EnvironmentValues {
    var appBackground: AppBackgroundStyle {
        get { self[AppBackgroundKey.self] }
        set { self[AppBackgroundKey.self] = newValue }
    }
}

extension Error {
    var isCancelledRequest: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        let nsError = self as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
