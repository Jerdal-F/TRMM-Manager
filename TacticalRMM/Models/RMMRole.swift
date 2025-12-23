import Foundation

struct RMMRole: Identifiable, Decodable, Hashable {
    let id: Int
    let name: String?

    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return "Role \(id)"
    }
}
