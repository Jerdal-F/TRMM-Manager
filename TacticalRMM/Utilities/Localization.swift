import Foundation

enum L10n {
    static func key(_ key: String, comment: String = "") -> String {
        if LocalizationDebug.showTranslationKeys { return key }
        return NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: comment)
    }

    static func format(_ key: String, comment: String = "", _ args: CVarArg...) -> String {
        if LocalizationDebug.showTranslationKeys { return key }
        let format = NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: comment)
        return String(format: format, arguments: args)
    }
}
