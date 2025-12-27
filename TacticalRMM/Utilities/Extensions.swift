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

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .default
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
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
