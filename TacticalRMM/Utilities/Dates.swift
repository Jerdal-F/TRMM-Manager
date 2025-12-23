import Foundation

enum DateConstants {
    static let lastSeenISOFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let lastSeenISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let lastSeenDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm dd/MM/yyyy"
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone.current
        return formatter
    }()
}

func formatLastSeenTimestamp(_ dateString: String?) -> String {
    guard let value = dateString?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return "N/A"
    }
    if let parsed = DateConstants.lastSeenISOFormatterWithFractional.date(from: value) ?? DateConstants.lastSeenISOFormatter.date(from: value) {
        return DateConstants.lastSeenDisplayFormatter.string(from: parsed)
    }
    return value
}
