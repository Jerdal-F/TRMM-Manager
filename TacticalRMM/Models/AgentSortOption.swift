import Foundation

enum AgentSortOption: String, CaseIterable, Identifiable {
    case none
    case windows
    case linux
    case mac
    case publicIP
    case online

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .windows: return "Windows"
        case .linux: return "Linux"
        case .mac: return "Mac"
        case .publicIP: return "Public IP"
        case .online: return "Online Agents"
        }
    }

    var chipLabel: String {
        switch self {
        case .none:
            return "Sort: None"
        case .windows, .linux, .mac:
            return "Sort: \(title)"
        case .publicIP:
            return "Sort: Public IP"
        case .online:
            return "Sort: Online"
        }
    }

    func matches(_ agent: Agent) -> Bool {
        switch self {
        case .none:
            return true
        case .windows:
            let os = agent.operating_system.lowercased()
            return os.contains("windows")
        case .linux:
            let os = agent.operating_system.lowercased()
            return os.contains("linux") || os.contains("ubuntu") || os.contains("debian") || os.contains("centos") || os.contains("fedora") || os.contains("red hat") || os.contains("suse") || os.contains("arch") || os.contains("rhel")
        case .mac:
            let os = agent.operating_system.lowercased()
            return os.contains("macos") || os.contains("mac os") || os.contains("os x") || os.contains("darwin")
        case .publicIP:
            return agent.public_ip?.nonEmpty != nil
        case .online:
            return agent.isOnlineStatus
        }
    }

    func sortKey(for agent: Agent) -> String {
        switch self {
        case .none:
            return agent.hostname.lowercased()
        case .windows, .linux, .mac:
            return agent.operating_system.lowercased()
        case .publicIP:
            return agent.public_ip?.lowercased() ?? ""
        case .online:
            return agent.hostname.lowercased()
        }
    }
}
