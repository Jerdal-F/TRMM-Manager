import SwiftUI

struct AgentRow: View {
    let agent: Agent
    let hideSensitiveInfo: Bool
    @AppStorage("lastSeenDateFormat") private var lastSeenDateFormat: String = ""

    private var statusColor: Color {
        if agent.isOnlineStatus { return Color.green }
        if agent.isOfflineStatus { return Color.red }
        return Color.orange
    }

    private var statusLabel: String {
        agent.statusDisplayLabel
    }

    private var publicIPText: String {
        hideSensitiveInfo ? "••••••" : (agent.public_ip ?? "No IP available")
    }

    private var lanIPText: String {
        guard !hideSensitiveInfo else { return "••••••" }
        if let value = agent.local_ips?.ipv4Only(), !value.isEmpty {
            return value
        }
        return "No LAN IP available"
    }

    private var lastSeenDisplay: String {
        formatLastSeenTimestamp(agent.last_seen, customFormat: lastSeenDateFormat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.hostname)
                        .font(.headline)
                    Text(agent.operating_system)
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.65))
                }
                Spacer()
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(statusLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
            }

            if let description = agent.description, !description.isEmpty {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(2)
            }

            VStack(alignment: .leading, spacing: 6) {
                if !agent.cpu_model.isEmpty {
                    Text(L10n.format("CPU: %@", agent.cpu_model.joined(separator: ", ")))
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.7))
                }

                Text(L10n.format("Site: %@", hideSensitiveInfo ? "••••••" : (agent.site_name ?? "Not available")))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.7))

                Text(L10n.format("LAN: %@", lanIPText))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.7))

                Text(L10n.format("Public: %@", publicIPText))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.7))
            }

            if let lastSeen = agent.last_seen, !lastSeen.isEmpty {
                Text(L10n.format("Last Seen: %@", lastSeenDisplay))
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }
}
