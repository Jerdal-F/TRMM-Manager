import Foundation

struct RMMUser: Identifiable, Decodable, Hashable {
    let id: Int
    let username: String
    let firstName: String?
    let lastName: String?
    let email: String?
    let isActive: Bool
    let lastLogin: String?
    let lastLoginIP: String?
    let role: Int?
    let blockDashboardLogin: Bool?
    let dateFormat: String?
    let socialAccounts: [Int]?

    private enum CodingKeys: String, CodingKey {
        case id
        case username
        case firstName = "first_name"
        case lastName = "last_name"
        case email
        case isActive = "is_active"
        case lastLogin = "last_login"
        case lastLoginIP = "last_login_ip"
        case role
        case blockDashboardLogin = "block_dashboard_login"
        case dateFormat = "date_format"
        case socialAccounts = "social_accounts"
    }

    var displayName: String {
        let components = [firstName, lastName].compactMap { value -> String? in
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }
        if components.isEmpty {
            return username
        }
        return components.joined(separator: " ")
    }

    var statusLabel: String { isActive ? "Active" : "Disabled" }

    var lastLoginDisplay: String {
        formatLastSeenTimestamp(lastLogin)
    }

    var roleLabel: String {
        guard let role else { return "Role unknown" }
        return "Role \(role)"
    }

    var canAccessDashboard: Bool {
        !(blockDashboardLogin ?? false)
    }
}
