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

    static let fallbackLastSeenFormat = "HH:mm dd/MM/yyyy"
    static let lastSeenFormatUserDefaultsKey = "lastSeenDateFormat"

    static func devicePreferredLastSeenFormat(locale: Locale = .current) -> String {
        let template = "yMdjmm"
        if let localized = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale), !localized.isEmpty {
            return localized
        }
        return fallbackLastSeenFormat
    }
}

private func resolvedLastSeenFormat(from rawValue: String?) -> String {
    let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty {
        return DateConstants.devicePreferredLastSeenFormat()
    }
    return trimmed
}

private func desiredLastSeenFormat(customFormat: String?) -> String {
    if let customFormat {
        return resolvedLastSeenFormat(from: customFormat)
    }
    let stored = UserDefaults.standard.string(forKey: DateConstants.lastSeenFormatUserDefaultsKey)
    return resolvedLastSeenFormat(from: stored)
}

private func formattedString(for date: Date, using format: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = format

    let formatted = formatter.string(from: date)
    if formatted.isEmpty {
        formatter.dateFormat = DateConstants.fallbackLastSeenFormat
        return formatter.string(from: date)
    }
    return formatted
}

func formatLastSeenDateValue(_ date: Date, customFormat: String? = nil) -> String {
    let format = desiredLastSeenFormat(customFormat: customFormat)
    return formattedString(for: date, using: format)
}

func formatLastSeenTimestamp(_ dateString: String?, customFormat: String? = nil) -> String {
    guard let value = dateString?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return "N/A"
    }
    if let parsed = DateConstants.lastSeenISOFormatterWithFractional.date(from: value) ?? DateConstants.lastSeenISOFormatter.date(from: value) {
        return formatLastSeenDateValue(parsed, customFormat: customFormat)
    }
    return value
}
