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
        DiagnosticLogger.shared.append("Saving API key to Keychain")

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
            DiagnosticLogger.shared.appendWarning("No API Key found in Keychain")
            return nil
        }

        cachedAPIKeys[account] = key
        DiagnosticLogger.shared.append("Retrieved API key from Keychain")
        return key
    }

    func deleteAPIKey(identifier: String? = nil) {
        let account = identifier ?? activeIdentifier
        cachedAPIKeys.removeValue(forKey: account)
        DiagnosticLogger.shared.append("Cleared cached API key")
        delete(account: account)
    }

    func clearCachedKeys() {
        cachedAPIKeys.removeAll()
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
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            DiagnosticLogger.shared.append("Keychain: Successfully saved API key")
        } else {
            DiagnosticLogger.shared.appendError("Keychain save failed with status: \(status)")
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
            DiagnosticLogger.shared.append("Keychain: Retrieved API key")
            return dataTypeRef as? Data
        case errSecItemNotFound:
            DiagnosticLogger.shared.appendWarning("Keychain read: no item found")
        default:
            DiagnosticLogger.shared.appendError("Keychain read failed with status: \(status)")
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
            DiagnosticLogger.shared.append("Keychain: Deleted API key")
        case errSecItemNotFound:
            DiagnosticLogger.shared.appendWarning("Keychain delete: no item to delete")
        default:
            DiagnosticLogger.shared.appendError("Keychain delete failed with status: \(status)")
        }
    }
}
