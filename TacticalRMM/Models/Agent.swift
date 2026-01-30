import Foundation
import SwiftUI

struct Agent: Identifiable, Decodable {
    var id: String { agent_id }
    let agent_id: String
    let hostname: String
    let operating_system: String
    let description: String?
    let cpu_model: [String]
    let public_ip: String?
    let local_ips: String?
    let graphics: String?
    let make_model: String?
    let status: String
    let site_name: String?
    let last_seen: String?
    let physical_disks: [String]?
    let custom_fields: [AgentCustomField]?
    let serial_number: String?
    let boot_time: TimeInterval?

    private enum CodingKeys: String, CodingKey {
        case agent_id, hostname, description, public_ip, local_ips, graphics, make_model, status, site_name, last_seen, physical_disks, custom_fields, serial_number, boot_time
        case operating_system
        case cpu_model
        case os
        case plat
    }

    init(agent_id: String,
         hostname: String,
         operating_system: String,
         description: String?,
         cpu_model: [String],
         public_ip: String?,
         local_ips: String?,
         graphics: String?,
         make_model: String?,
         status: String,
         site_name: String?,
         last_seen: String?,
         physical_disks: [String]?,
         custom_fields: [AgentCustomField]?,
         serial_number: String?,
         boot_time: TimeInterval?) {
        self.agent_id = agent_id
        self.hostname = hostname
        self.operating_system = operating_system
        self.description = description
        self.cpu_model = cpu_model
        self.public_ip = public_ip
        self.local_ips = local_ips
        self.graphics = graphics
        self.make_model = make_model
        self.status = status
        self.site_name = site_name
        self.last_seen = last_seen
        self.physical_disks = physical_disks
        self.custom_fields = custom_fields
        self.serial_number = serial_number
        self.boot_time = boot_time
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent_id = try c.decode(String.self, forKey: .agent_id)
        hostname = try c.decode(String.self, forKey: .hostname)

        if let os = try c.decodeIfPresent(String.self, forKey: .operating_system) {
            operating_system = os
        } else if let osAlt = try c.decodeIfPresent(String.self, forKey: .os) {
            operating_system = osAlt
        } else if let plat = try c.decodeIfPresent(String.self, forKey: .plat) {
            operating_system = plat
        } else {
            operating_system = "Unknown OS"
        }

        if let cpuArr = try c.decodeIfPresent([String].self, forKey: .cpu_model) {
            cpu_model = cpuArr
        } else if let cpuStr = try c.decodeIfPresent(String.self, forKey: .cpu_model) {
            cpu_model = cpuStr.isEmpty ? [] : [cpuStr]
        } else {
            cpu_model = []
        }

        description = try c.decodeIfPresent(String.self, forKey: .description)
        public_ip = try c.decodeIfPresent(String.self, forKey: .public_ip)
        local_ips = try c.decodeIfPresent(String.self, forKey: .local_ips)
        graphics = try c.decodeIfPresent(String.self, forKey: .graphics)
        make_model = try c.decodeIfPresent(String.self, forKey: .make_model)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        site_name = try c.decodeIfPresent(String.self, forKey: .site_name)
        last_seen = try c.decodeIfPresent(String.self, forKey: .last_seen)
        physical_disks = try c.decodeIfPresent([String].self, forKey: .physical_disks)
        custom_fields = try c.decodeIfPresent([AgentCustomField].self, forKey: .custom_fields)
        serial_number = try c.decodeIfPresent(String.self, forKey: .serial_number)
        boot_time = try c.decodeIfPresent(TimeInterval.self, forKey: .boot_time)
    }
}

extension Agent {
    var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isOnlineStatus: Bool {
        normalizedStatus == "online"
    }

    var isOfflineStatus: Bool {
        ["offline", "overdue", "dormant"].contains(normalizedStatus)
    }

    var statusDisplayLabel: String {
        switch normalizedStatus {
        case "online":
            return L10n.key("agents.status.online")
        case "offline":
            return L10n.key("agents.status.offline")
        case "overdue":
            return L10n.key("agents.status.overdue")
        case "dormant":
            return L10n.key("agents.status.dormant")
        case "", "unknown":
            return L10n.key("agents.status.unknown")
        default:
            return status.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
        }
    }
}
