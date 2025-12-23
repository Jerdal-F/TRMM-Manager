import Foundation

struct RMMDeployment: Identifiable, Decodable {
    struct InstallFlags: Decodable {
        let rdp: Bool?
        let ping: Bool?
        let power: Bool?

        private enum CodingKeys: String, CodingKey {
            case rdp
            case ping
            case power
        }
    }

    let id: Int
    let uid: String
    let clientID: Int
    let siteID: Int
    let clientName: String
    let siteName: String
    let monType: String
    let goArch: String
    let expiry: String?
    let installFlags: InstallFlags?
    let created: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case uid
        case clientID = "client_id"
        case siteID = "site_id"
        case clientName = "client_name"
        case siteName = "site_name"
        case monType = "mon_type"
        case goArch = "goarch"
        case expiry
        case installFlags = "install_flags"
        case created
    }

    var displayTitle: String {
        if siteName.isEmpty {
            return clientName
        }
        return "\(clientName) · \(siteName)"
    }

    var expiryDisplayText: String {
        formatLastSeenTimestamp(expiry)
    }

    var createdDisplayText: String {
        formatLastSeenTimestamp(created)
    }
}
