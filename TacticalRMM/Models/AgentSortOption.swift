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
        case .none: return L10n.key("agents.sort.none")
        case .windows: return L10n.key("agents.sort.windows")
        case .linux: return L10n.key("agents.sort.linux")
        case .mac: return L10n.key("agents.sort.mac")
        case .publicIP: return L10n.key("agents.sort.publicIP")
        case .online: return L10n.key("agents.sort.online")
        }
    }

    var chipLabel: String {
        L10n.format("agents.sort.chipFormat", title)
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
