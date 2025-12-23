import Foundation
import Combine

@MainActor
final class AgentCache: ObservableObject {
    static let shared = AgentCache()

    @Published private(set) var agents: [Agent] = []

    private init() {}

    func setAgents(_ newAgents: [Agent]) {
        agents = newAgents.sorted { lhs, rhs in
            lhs.hostname.localizedCaseInsensitiveCompare(rhs.hostname) == .orderedAscending
        }
    }

    func clear() {
        agents.removeAll()
    }
}
