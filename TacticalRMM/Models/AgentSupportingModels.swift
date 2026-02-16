import Foundation

struct AgentListResponse: Decodable {
    let count: Int?
    let next: String?
    let previous: String?
    let results: [Agent]
}

struct MeshCentralResponse: Decodable {
    let hostname: String
    let control: String
    let terminal: String
    let file: String
    let status: String
    let client: String
    let site: String
}

struct ScriptResults: Codable {
    let id: Int?
    let stderr: String?
    var stdout: String?
    let retcode: Int?
    let executionTime: Double?
    let scriptName: String?

    enum CodingKeys: String, CodingKey {
        case id, stderr, stdout, retcode
        case executionTime = "execution_time"
        case scriptName = "script_name"
    }
}

struct ScriptEnvVar: Identifiable, Codable {
    let name: String
    let value: String?
    let description: String?
    let required: Bool?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, value, description, required
    }
}

struct RMMScript: Identifiable, Decodable {
    let id: Int
    let name: String
    let description: String?
    let scriptType: String
    let shell: String
    let args: [String]
    let category: String?
    let favorite: Bool
    let defaultTimeout: Int
    let syntax: String?
    let filename: String?
    let hidden: Bool
    let supportedPlatforms: [String]
    let runAsUser: Bool
    let envVars: [ScriptEnvVar]

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case scriptType = "script_type"
        case shell, args, category, favorite
        case defaultTimeout = "default_timeout"
        case syntax, filename, hidden
        case supportedPlatforms = "supported_platforms"
        case runAsUser = "run_as_user"
        case envVars = "env_vars"
    }

    init(id: Int,
         name: String,
         description: String?,
         scriptType: String,
         shell: String,
         args: [String],
         category: String?,
         favorite: Bool,
         defaultTimeout: Int,
         syntax: String?,
         filename: String?,
         hidden: Bool,
         supportedPlatforms: [String],
         runAsUser: Bool,
         envVars: [ScriptEnvVar]) {
        self.id = id
        self.name = name
        self.description = description
        self.scriptType = scriptType
        self.shell = shell
        self.args = args
        self.category = category
        self.favorite = favorite
        self.defaultTimeout = defaultTimeout
        self.syntax = syntax
        self.filename = filename
        self.hidden = hidden
        self.supportedPlatforms = supportedPlatforms
        self.runAsUser = runAsUser
        self.envVars = envVars
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        scriptType = try container.decodeIfPresent(String.self, forKey: .scriptType) ?? "unknown"
        shell = try container.decodeIfPresent(String.self, forKey: .shell) ?? "powershell"
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        category = try container.decodeIfPresent(String.self, forKey: .category)
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        defaultTimeout = try container.decodeIfPresent(Int.self, forKey: .defaultTimeout) ?? 90
        syntax = try container.decodeIfPresent(String.self, forKey: .syntax)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        supportedPlatforms = try container.decodeIfPresent([String].self, forKey: .supportedPlatforms) ?? []
        runAsUser = try container.decodeIfPresent(Bool.self, forKey: .runAsUser) ?? false
        envVars = try container.decodeIfPresent([ScriptEnvVar].self, forKey: .envVars) ?? []
    }
}

struct ProcessRecord: Identifiable, Decodable {
    let id: Int
    let name: String
    let pid: Int
    let membytes: Int
    let username: String
    let cpu_percent: String
}

struct SoftwareInventoryResponse: Decodable {
    let id: Int?
    let software: [InstalledSoftware]
    let agent: Int?
}

struct InstalledSoftware: Identifiable, Decodable {
    let name: String
    let size: String
    let source: String
    let version: String
    let location: String
    let publisher: String
    let uninstall: String
    let install_date: String

    var id: String {
        "\(name)|\(version)|\(location)|\(install_date)"
    }
}

struct ServiceInventoryResponse: Decodable {
    let services: [AgentService]
}

struct AgentService: Identifiable, Decodable {
    let name: String
    let status: String
    let display_name: String
    let binpath: String
    let description: String
    let username: String
    let pid: Int
    let start_type: String
    let autodelay: Bool

    var id: String {
        "\(name)|\(display_name)|\(username)|\(start_type)"
    }
}

struct Note: Identifiable, Decodable {
    let pk: Int
    let entry_time: String
    let note: String
    let username: String
    let agent_id: String

    var id: Int { pk }
}

struct AgentTask: Identifiable, Decodable {
    let id: Int
    let schedule: String
    let run_time_date: String
    let name: String
    let created_by: String
    let created_time: String
    let modified_by: String?
    let modified_time: String?
    let task_result: TaskResult?
    let actions: [TaskAction]?
}

struct TaskResult: Decodable {
    let id: Int
    let retcode: Int
    let stdout: String
    let stderr: String
    let execution_time: String
    let last_run: String
    let status: String
    let sync_status: String
    let locked_at: String?
    let run_status: String
    let agent: Int?
    let task: Int?
}

struct TaskAction: Decodable {
    let name: String
    let type: String
    let script: Int
    let timeout: Int
    let env_vars: [String]
    let script_args: [String]
}

struct CheckResult: Decodable {
    let id: Int
    let status: String
    let alert_severity: String?
    let more_info: String?
    let last_run: String
    let fail_count: Int?
    let outage_history: String?
    let extra_details: String?
    let stdout: String?
    let stderr: String?
    let retcode: Int?
    let execution_time: String?
}

struct AgentCheck: Identifiable, Decodable {
    let id: Int
    let readable_desc: String
    let check_result: CheckResult?
    let created_by: String
    let created_time: String
}

struct Site: Identifiable, Decodable {
    let id: Int
    let name: String
}

struct ClientModel: Identifiable, Decodable {
    let id: Int
    let name: String
    let sites: [Site]
}

struct RMMClient: Identifiable, Decodable {
    let id: Int
    let name: String
    let sites: [RMMClientSite]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case sites
    }
}

struct RMMClientSite: Identifiable, Decodable {
    let id: Int
    let name: String
    let clientID: Int
    let clientName: String

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case clientID = "client"
        case clientName = "client_name"
    }
}
