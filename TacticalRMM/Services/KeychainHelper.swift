import Foundation
import Security

final class KeychainHelper {
    static let shared = KeychainHelper()

    private init() {}

    private let service = "jerdal.TacticalRMM-Manager"
    private var cachedAPIKeys: [String: String] = [:]
    private var activeIdentifier: String = "apiKey"

    func setActiveIdentifier(_ identifier: String) {
        activeIdentifier = identifier
    }

    func saveAPIKey(_ apiKey: String, identifier: String? = nil) {
        let account = identifier ?? activeIdentifier
        cachedAPIKeys[account] = apiKey
        DiagnosticLogger.shared.append("Saving API key for account '\(account)'")

        guard let data = apiKey.data(using: .utf8) else {
            DiagnosticLogger.shared.appendError("Failed to encode API key to Data")
            return
        }

        save(data, for: account)
    }

    func getAPIKey(identifier: String? = nil) -> String? {
        let account = identifier ?? activeIdentifier
        if let key = cachedAPIKeys[account] {
            return key
        }

        guard let data = read(account: account), let key = String(data: data, encoding: .utf8) else {
            DiagnosticLogger.shared.appendWarning("No API Key found in Keychain for account '\(account)'")
            return nil
        }

        cachedAPIKeys[account] = key
        DiagnosticLogger.shared.append("Retrieved API key from Keychain for account '\(account)'")
        return key
    }

    func deleteAPIKey(identifier: String? = nil) {
        let account = identifier ?? activeIdentifier
        cachedAPIKeys.removeValue(forKey: account)
        DiagnosticLogger.shared.append("Cleared cached API key for account '\(account)'")
        delete(account: account)
    }

    func deleteAllAPIKeys() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            DiagnosticLogger.shared.append("Keychain: Cleared all stored API keys")
        } else {
            DiagnosticLogger.shared.appendError("Keychain bulk delete failed with status: \(status)")
        }
        cachedAPIKeys.removeAll()
        activeIdentifier = "apiKey"
    }

    private func save(_ data: Data, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            DiagnosticLogger.shared.append("Keychain: Successfully saved item for account '\(account)'")
        } else {
            DiagnosticLogger.shared.appendError("Keychain save failed for account '\(account)' with status: \(status)")
        }
    }

    private func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        switch status {
        case errSecSuccess:
            DiagnosticLogger.shared.append("Keychain: Retrieved data for account '\(account)'")
            return dataTypeRef as? Data
        case errSecItemNotFound:
            DiagnosticLogger.shared.appendWarning("Keychain read: no item found for account '\(account)'")
        default:
            DiagnosticLogger.shared.appendError("Keychain read failed for account '\(account)' with status: \(status)")
        }
        return nil
    }

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess:
            DiagnosticLogger.shared.append("Keychain: Deleted item for account '\(account)'")
        case errSecItemNotFound:
            DiagnosticLogger.shared.appendWarning("Keychain delete: no item to delete for account '\(account)'")
        default:
            DiagnosticLogger.shared.appendError("Keychain delete failed for account '\(account)' with status: \(status)")
        }
    }
}
