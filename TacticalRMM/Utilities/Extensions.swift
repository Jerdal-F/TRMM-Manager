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
