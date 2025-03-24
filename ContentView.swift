import SwiftUI
import SwiftData
import Security

// MARK: - Diagnostic Logger
class DiagnosticLogger {
    static let shared = DiagnosticLogger()
    private let fileName: String
    private var logFileURL: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return docs.appendingPathComponent(fileName)
    }
    private init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MM-yyyy HH-mm-ss"
        let dateString = formatter.string(from: Date())
        self.fileName = "\(dateString)-TRMM Manager.log"
    }
    
    func append(_ message: String) {
        // Log messages as provided without sanitization.
        guard let url = logFileURL else { return }
        let logEntry = "\(Date()): \(message)\n"
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let fileHandle = try FileHandle(forWritingTo: url)
                fileHandle.seekToEndOfFile()
                if let data = logEntry.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
            } else {
                try logEntry.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            print("Error writing log: \(error)")
        }
    }
    
    /// Masks an API key so that only the first 4 and last 4 characters are visible.
    func maskAPIKey(_ key: String) -> String {
        let length = key.count
        if length <= 8 {
            return String(repeating: "X", count: length)
        }
        let first = key.prefix(4)
        let last = key.suffix(4)
        return "\(first)XXXXXXXXXXXXXX\(last)"
    }
    
    /// Logs the HTTP response including a truncated response body.
    func logHTTPResponse(method: String, url: String, status: Int, data: Data?) {
        let responseBody: String
        if let data = data, let responseString = String(data: data, encoding: .utf8) {
            responseBody = responseString.count > 200 ? String(responseString.prefix(200)) + "..." : responseString
        } else {
            responseBody = "No response body."
        }
        append("HTTP Response: \(status) for \(method) \(url). Response Body: \(responseBody)")
    }
    
    /// Logs warnings with a "WARNING:" prefix.
    func appendWarning(_ message: String) {
        append("WARNING: \(message)")
    }
    
    /// Logs errors with an "ERROR:" prefix.
    func appendError(_ message: String) {
        append("ERROR: \(message)")
    }
    
    func getLogFileURL() -> URL? {
        return logFileURL
    }
    
    // MARK: - New Helper Methods to Sanitize HTTP Logging
    
    /// Returns a sanitized copy of the headers where the "X-API-KEY" is replaced.
    private func sanitizeHeaders(_ headers: [String: String]) -> [String: String] {
        var sanitized = headers
        if sanitized["X-API-KEY"] != nil {
            sanitized["X-API-KEY"] = "[REDACTED]"
        }
        return sanitized
    }
    
    /// Logs an HTTP request after sanitizing its headers.
    func logHTTPRequest(method: String, url: String, headers: [String: String]) {
        let sanitized = sanitizeHeaders(headers)
        append("HTTP Request: \(method) \(url) Headers: \(sanitized)")
    }
}

// MARK: - Keychain Helper

struct KeychainHelper {
    static let shared = KeychainHelper()
    private let service = "jerdal.TacticalRMM-Manager"

    func save(_ data: Data, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        DiagnosticLogger.shared.append("Keychain save status for \(account): \(status)")
    }
    
    func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return data
        }
        return nil
    }
    
    func saveAPIKey(_ apiKey: String) {
        if let data = apiKey.data(using: .utf8) {
            DiagnosticLogger.shared.append("Saving API Key: \(DiagnosticLogger.shared.maskAPIKey(apiKey))")
            save(data, for: "apiKey")
        }
    }
    
    func getAPIKey() -> String? {
        if let data = read(account: "apiKey") {
            let apiKey = String(data: data, encoding: .utf8)
            if let key = apiKey {
                DiagnosticLogger.shared.append("Retrieved API Key: \(DiagnosticLogger.shared.maskAPIKey(key))")
            }
            return apiKey
        }
        return nil
    }
    
    func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "apiKey"
        ]
        SecItemDelete(query as CFDictionary)
        DiagnosticLogger.shared.append("Deleted API Key from Keychain")
    }
}

// MARK: - Activity View for Sharing

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems,
                                 applicationActivities: applicationActivities)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Extensions

extension URLRequest {
    mutating func addDefaultHeaders(apiKey: String) {
        self.addValue("*/*", forHTTPHeaderField: "accept")
        self.addValue(apiKey, forHTTPHeaderField: "X-API-KEY")
    }
}

extension UIApplication {
    func dismissKeyboard() {
        sendAction(#selector(UIResponder.resignFirstResponder),
                   to: nil, from: nil, for: nil)
    }
}

extension String {
    func ipv4Only() -> String {
        let ips = self.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let ipv4s = ips.filter { !$0.contains(":") }
        return ipv4s.joined(separator: ", ")
    }
    
    func removingTrailingSlash() -> String {
        if self.hasSuffix("/") {
            return String(self.dropLast())
        }
        return self
    }
}

// MARK: - Models

@Model
final class RMMSettings {
    var baseURL: String
    init(baseURL: String) {
        self.baseURL = baseURL
    }
}

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

struct HistoryRecord: Identifiable, Decodable {
    let id: Int
    let time: String
    let type: String
    let command: String
    let username: String
    let results: String?
    let script_results: ScriptResults?
    let collector_all_output: Bool?
    let save_to_agent_note: Bool?
    let agent: Int?
    let script: Int?
    let custom_field: String?
}

struct ScriptResults: Decodable {
    let stderr: String?
    let stdout: String?
    let retcode: Int?
    let execution_time: Double?
}

struct ProcessRecord: Identifiable, Decodable {
    let id: Int
    let name: String
    let pid: Int
    let membytes: Int
    let username: String
    let cpu_percent: String
}

// MARK: - ContentView

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsList: [RMMSettings]
    
    @State private var baseURLText: String = ""
    @State private var apiKeyText: String = ""
    @State private var showSavedAlert: Bool = false
    @State private var showGuideAlert: Bool = false
    @State private var agents: [Agent] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var showDiagnosticAlert: Bool = false
    @State private var showLogShareSheet: Bool = false
    @FocusState private var isInputActive: Bool
    
    // Search-related states
    @State private var searchText: String = ""
    @State private var appliedSearchText: String = ""
    @State private var showSearch: Bool = false
    @FocusState private var searchFieldIsFocused: Bool  // Focus state for the search field
    
    // Filter agents based on applied search text.
    var filteredAgents: [Agent] {
        if appliedSearchText.isEmpty {
            return agents
        } else {
            return agents.filter { agent in
                agent.hostname.localizedCaseInsensitiveContains(appliedSearchText) ||
                agent.operating_system.localizedCaseInsensitiveContains(appliedSearchText)
            }
        }
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("API Settings"),
                        footer: Text("Note: You might experience issues if you have a large number of agents due to hardware limitations.")) {
                    TextField("API URL", text: $baseURLText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .focused($isInputActive)
                    SecureField("API Key", text: $apiKeyText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .focused($isInputActive)
                    if baseURLText.isEmpty || apiKeyText.isEmpty {
                        Text("Please enter both Base URL and API Key")
                            .foregroundColor(.red)
                    } else if baseURLText.removingTrailingSlash().lowercased() == "demo" &&
                                apiKeyText.lowercased() == "demo" {
                        Button("Demo Mode") {
                            DiagnosticLogger.shared.append("Demo mode login triggered.")
                            isInputActive = false
                            loadDemoAgents()
                        }
                        .buttonStyle(.borderedProminent)
                    } else if let savedSettings = settingsList.first,
                              savedSettings.baseURL == baseURLText,
                              KeychainHelper.shared.getAPIKey() == apiKeyText {
                        Button("Login") {
                            DiagnosticLogger.shared.append("User tapped login (existing settings).")
                            isInputActive = false
                            Task {
                                await fetchAgents(using: savedSettings)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Save & Login") {
                            DiagnosticLogger.shared.append("User tapped save & login (new settings).")
                            isInputActive = false
                            Task {
                                await updateSettingsAndFetch()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                // Custom header for the Agents section.
                Section(header: HStack {
                    Text("Agents")
                        .font(.headline)
                    Spacer()
                    if showSearch {
                        TextField("Search agents", text: $searchText)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 200)
                            .focused($searchFieldIsFocused)
                            .submitLabel(.search)
                            .onSubmit {
                                appliedSearchText = searchText
                            }
                    } else {
                        Button {
                            withAnimation {
                                showSearch = true
                                searchFieldIsFocused = true
                            }
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                }
                .transaction { transaction in
                    transaction.animation = nil
                }) {
                    if isLoading {
                        ProgressView("Loading agents...")
                    }
                    if let errorMessage = errorMessage {
                        Text("Error: \(errorMessage)")
                            .foregroundColor(.red)
                    }
                    ForEach(filteredAgents) { agent in
                        NavigationLink(destination: AgentDetailView(
                            agent: agent,
                            baseURL: baseURLText,
                            apiKey: apiKeyText
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(agent.hostname)
                                    .font(.headline)
                                Text(agent.operating_system)
                                    .font(.subheadline)
                                if let desc = agent.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text("Status: \(agent.status)")
                                    .font(.caption)
                                    .foregroundColor(agent.status.lowercased() == "online" ? .green : .red)
                                if !agent.cpu_model.isEmpty {
                                    Text("CPU: \(agent.cpu_model.joined(separator: ", "))")
                                        .font(.caption)
                                }
                                if let publicIP = agent.public_ip {
                                    Text("Public IP: \(publicIP)")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.never)
            .alert(isPresented: $showGuideAlert) {
                Alert(
                    title: Text("Welcome"),
                    message: Text("Seems like you're new here, we recommend reading the guide."),
                    primaryButton: .default(Text("Read Guide"), action: {
                        if let url = URL(string: "https://github.com/Jerdal-F/TacticalRMM-Manager/blob/main/README.md") {
                            UIApplication.shared.open(url)
                        }
                    }),
                    secondaryButton: .cancel(Text("Disregard"))
                )
            }
            .alert("Diagnostics", isPresented: $showDiagnosticAlert) {
                Button("Save", role: .destructive) {
                    showLogShareSheet = true
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Do you want to export the diagnostics log file?")
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack {
                        Text("Tactical RMM")
                            .font(.headline)
                        Text("Agent Manager")
                            .font(.subheadline)
                    }
                    .contentShape(Rectangle())
                    .onLongPressGesture(
                        minimumDuration: 2,
                        maximumDistance: 50,
                        pressing: { isPressing in
                            DiagnosticLogger.shared.append("Tactical RMM label pressing: \(isPressing)")
                        },
                        perform: {
                            DiagnosticLogger.shared.append("Tactical RMM label long-pressed for diagnostics export.")
                            showDiagnosticAlert = true
                        }
                    )
                }
            }
            .onAppear {
                DiagnosticLogger.shared.append("ContentView onAppear")
                if let savedSettings = settingsList.first {
                    baseURLText = savedSettings.baseURL
                    apiKeyText = KeychainHelper.shared.getAPIKey() ?? ""
                }
                if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
                    showGuideAlert = true
                    UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
                }
            }
            .alert("Settings Saved", isPresented: $showSavedAlert) {
                Button("OK", role: .cancel) { }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $showLogShareSheet) {
            if let url = DiagnosticLogger.shared.getLogFileURL() {
                ActivityView(activityItems: [url])
            } else {
                Text("No diagnostics log file available.")
            }
        }
    }
    
    // MARK: - Helper Functions
    
    @MainActor
    private func updateSettingsAndFetch() async {
        DiagnosticLogger.shared.append("updateSettingsAndFetch started")
        baseURLText = baseURLText.removingTrailingSlash()
        // Ensure the URL includes the scheme unless in demo mode.
        if baseURLText.lowercased() != "demo" && !baseURLText.lowercased().hasPrefix("http://") && !baseURLText.lowercased().hasPrefix("https://") {
            baseURLText = "https://" + baseURLText
        }
        if let savedSettings = settingsList.first {
            savedSettings.baseURL = baseURLText
            KeychainHelper.shared.saveAPIKey(apiKeyText)
            await saveSettingsAndFetch(settings: savedSettings)
        } else {
            DiagnosticLogger.shared.append("Creating new settings.")
            let newSettings = RMMSettings(baseURL: baseURLText)
            modelContext.insert(newSettings)
            KeychainHelper.shared.saveAPIKey(apiKeyText)
            await saveSettingsAndFetch(settings: newSettings)
        }
    }
    
    @MainActor
    private func saveSettingsAndFetch(settings: RMMSettings) async {
        do {
            try modelContext.save()
            DiagnosticLogger.shared.append("Settings saved successfully.")
            showSavedAlert = true
            UIApplication.shared.dismissKeyboard()
            await fetchAgents(using: settings)
        } catch {
            DiagnosticLogger.shared.appendError("Error saving settings: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    private func fetchAgents(using settings: RMMSettings) async {
        DiagnosticLogger.shared.append("fetchAgents started")
        let sanitizedURL = settings.baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/") else {
            errorMessage = "Invalid URL."
            DiagnosticLogger.shared.appendError("Invalid URL when fetching agents.")
            return
        }
        isLoading = true
        errorMessage = nil
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let apiKey = KeychainHelper.shared.getAPIKey() ?? ""
        request.addDefaultHeaders(apiKey: apiKey)
        DiagnosticLogger.shared.logHTTPRequest(method: "GET", url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(method: "GET", url: url.absoluteString, status: httpResponse.statusCode, data: data)
                if httpResponse.statusCode == 401 {
                    errorMessage = "Invalid API Key."
                    DiagnosticLogger.shared.appendError("HTTP 401: Invalid API Key during agents fetch.")
                    return
                } else if httpResponse.statusCode != 200 {
                    errorMessage = "HTTP Error: \(httpResponse.statusCode)"
                    DiagnosticLogger.shared.appendError("HTTP Error \(httpResponse.statusCode) during agents fetch.")
                    return
                }
            }
            let decodedAgents = try JSONDecoder().decode([Agent].self, from: data)
            agents = decodedAgents
            DiagnosticLogger.shared.append("Fetched agents successfully. Count: \(decodedAgents.count)")
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Error fetching agents: \(error.localizedDescription)")
        }
        isLoading = false
    }
    
    private func loadDemoAgents() {
        DiagnosticLogger.shared.append("Loading demo agents.")
        let demoAgents = [
            Agent(
                agent_id: "demo1",
                hostname: "Demo Agent 1",
                operating_system: "iOS Demo OS",
                description: "This is a demo agent.",
                cpu_model: ["Demo CPU"],
                public_ip: "192.0.2.1",
                local_ips: "10.0.0.1",
                graphics: "Demo GPU",
                make_model: "Demo Model",
                status: "online",
                site_name: "Demo Site",
                last_seen: ISO8601DateFormatter().string(from: Date()),
                physical_disks: ["Demo Disk 1"]
            ),
            Agent(
                agent_id: "demo2",
                hostname: "Demo Agent 2",
                operating_system: "iOS Demo OS",
                description: "Another demo agent.",
                cpu_model: ["Demo CPU"],
                public_ip: "192.0.2.2",
                local_ips: "10.0.0.2",
                graphics: "Demo GPU",
                make_model: "Demo Model",
                status: "offline",
                site_name: "Demo Site",
                last_seen: ISO8601DateFormatter().string(from: Date()),
                physical_disks: ["Demo Disk 2"]
            )
        ]
        agents = demoAgents
    }
}

// MARK: - AgentDetailView

struct AgentDetailView: View {
    let agent: Agent
    let baseURL: String
    let apiKey: String
    
    @State private var updatedAgent: Agent?
    @State private var isProcessing: Bool = false
    @State private var message: String? = nil
    @State private var meshCentralResponse: MeshCentralResponse?
    @State private var isLoadingMeshCentral: Bool = false
    @State private var meshCentralError: String? = nil
    @State private var showShutdownConfirmation: Bool = false
    
    var effectiveAPIKey: String {
        return KeychainHelper.shared.getAPIKey() ?? apiKey
    }
    private var isDemoMode: Bool {
        return baseURL.removingTrailingSlash().lowercased() == "demo" &&
               effectiveAPIKey.lowercased() == "demo"
    }
    
    func formattedLastSeen(from dateString: String?) -> String {
        guard let dateString = dateString else { return "N/A" }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = isoFormatter.date(from: dateString) else { return "N/A" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm dd/MM/yyyy"
        return formatter.string(from: date)
    }
    
    @MainActor
    func fetchAgentDetail() async {
        if isDemoMode {
            DiagnosticLogger.shared.append("Demo mode active, skipping fetchAgentDetail.")
            updatedAgent = agent
            return
        }
        DiagnosticLogger.shared.append("AgentDetailView: fetchAgentDetail started")
        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/\(agent.agent_id)/") else {
            message = "Invalid URL for agent details"
            DiagnosticLogger.shared.appendError("Invalid URL when fetching agent details.")
            return
        }
        isProcessing = true
        defer { isProcessing = false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addDefaultHeaders(apiKey: effectiveAPIKey)
        DiagnosticLogger.shared.logHTTPRequest(method: "GET", url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(method: "GET", url: url.absoluteString, status: httpResponse.statusCode, data: data)
                if httpResponse.statusCode != 200 {
                    message = "HTTP Error: \(httpResponse.statusCode)"
                    DiagnosticLogger.shared.appendError("HTTP Error \(httpResponse.statusCode) during agent detail fetch.")
                    return
                }
            }
            let decodedAgent = try JSONDecoder().decode(Agent.self, from: data)
            updatedAgent = decodedAgent
            DiagnosticLogger.shared.append("Fetched updated details for agent.")
        } catch {
            message = "Error fetching agent details: \(error.localizedDescription)"
            DiagnosticLogger.shared.appendError("Error fetching agent details: \(error.localizedDescription)")
        }
    }
    
    // Moved from MoreActionsView
    @MainActor
    func performWakeOnLan() async {
        isProcessing = true
        message = nil
        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/\(agent.agent_id)/wol/") else {
            message = "Invalid URL"
            DiagnosticLogger.shared.appendError("Invalid URL in Wake‑On‑Lan.")
            isProcessing = false
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addDefaultHeaders(apiKey: effectiveAPIKey)
        request.httpBody = Data()
        DiagnosticLogger.shared.logHTTPRequest(method: "POST", url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(method: "POST", url: url.absoluteString, status: httpResponse.statusCode, data: data)
                if httpResponse.statusCode == 200 {
                    if let responseString = String(data: data, encoding: .utf8) {
                        message = responseString
                    } else {
                        message = "Wake‑on‑LAN sent successfully!"
                    }
                } else {
                    message = "HTTP Error: \(httpResponse.statusCode)"
                }
            } else {
                message = "Unknown error"
            }
        } catch {
            message = "Error: \(error.localizedDescription)"
            DiagnosticLogger.shared.appendError("Error in Wake‑On‑Lan: \(error.localizedDescription)")
        }
        isProcessing = false
    }
    
    @MainActor
    func performAction(action: String) async {
        if isDemoMode {
            message = "Demo mode does not support \(action) action."
            DiagnosticLogger.shared.append("Demo mode: skipping \(action) command.")
            return
        }
        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/\(agent.agent_id)/\(action)/") else {
            message = "Invalid URL"
            DiagnosticLogger.shared.appendError("Invalid URL for \(action) command.")
            return
        }
        isProcessing = true
        message = nil
        defer { isProcessing = false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addDefaultHeaders(apiKey: effectiveAPIKey)
        request.httpBody = Data()
        DiagnosticLogger.shared.logHTTPRequest(method: "POST", url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:])
        DiagnosticLogger.shared.append("Sent POST request to \(action)")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(method: "POST", url: url.absoluteString, status: httpResponse.statusCode, data: Data())
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 {
                    message = "\(action.capitalized) command sent successfully!"
                    DiagnosticLogger.shared.append("API returned \(httpResponse.statusCode), \(action) command confirmed by API.")
                } else if httpResponse.statusCode == 400 {
                    message = "HTTP 400 Bad Request, the agent might be offline"
                    DiagnosticLogger.shared.appendWarning("HTTP 400 encountered during \(action) command.")
                } else {
                    message = "HTTP Error: \(httpResponse.statusCode)"
                    DiagnosticLogger.shared.appendError("HTTP Error \(httpResponse.statusCode) during \(action) command.")
                }
            } else {
                message = "Unknown error"
                DiagnosticLogger.shared.appendError("Unknown error during \(action) command.")
            }
        } catch {
            message = "Error: \(error.localizedDescription)"
            DiagnosticLogger.shared.appendError("Error during \(action) command: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    func fetchMeshCentralData() async -> MeshCentralResponse? {
        if isDemoMode {
            DiagnosticLogger.shared.append("Demo mode active, skipping MeshCentral data fetch.")
            meshCentralError = "Demo mode: MeshCentral data not available."
            return nil
        }
        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/\(agent.agent_id)/meshcentral/") else {
            meshCentralError = "Invalid URL for meshcentral."
            DiagnosticLogger.shared.appendError("Invalid URL when fetching MeshCentral data.")
            return nil
        }
        isLoadingMeshCentral = true
        meshCentralError = nil
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addDefaultHeaders(apiKey: effectiveAPIKey)
        DiagnosticLogger.shared.logHTTPRequest(method: "GET", url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:])
        defer { isLoadingMeshCentral = false }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(method: "GET", url: url.absoluteString, status: httpResponse.statusCode, data: data)
                if httpResponse.statusCode != 200 {
                    meshCentralError = "HTTP Error: \(httpResponse.statusCode)"
                    DiagnosticLogger.shared.appendError("HTTP Error \(httpResponse.statusCode) during MeshCentral data fetch.")
                    return nil
                }
            }
            let decoded = try JSONDecoder().decode(MeshCentralResponse.self, from: data)
            DiagnosticLogger.shared.append("MeshCentral data fetched successfully for action.")
            return decoded
        } catch {
            meshCentralError = error.localizedDescription
            DiagnosticLogger.shared.appendError("Error fetching MeshCentral data: \(error.localizedDescription)")
            return nil
        }
    }
    
    @MainActor
    func takeControl() async {
        if isDemoMode {
            message = "Demo mode does not support Take Control."
            DiagnosticLogger.shared.append("Demo mode: skipping Take Control action.")
            return
        }
        guard let meshData = await fetchMeshCentralData() else {
            message = "Failed to fetch MeshCentral data for Take Control."
            DiagnosticLogger.shared.appendError("Failed to fetch MeshCentral data for Take Control.")
            return
        }
        guard let url = URL(string: meshData.control) else {
            message = "Invalid URL for Take Control."
            DiagnosticLogger.shared.appendError("Invalid URL encountered in Take Control action.")
            return
        }
        DiagnosticLogger.shared.append("Initiating Take Control action.")
        let success = await UIApplication.shared.open(url)
        if !success {
            message = "Failed to open Take Control URL."
            DiagnosticLogger.shared.appendError("Failed to open URL during Take Control action.")
        } else {
            message = "Take Control URL opened successfully."
        }
    }
    
    @MainActor
    func openConsole() async {
        if isDemoMode {
            message = "Demo mode does not support Console."
            DiagnosticLogger.shared.append("Demo mode: skipping Console action.")
            return
        }
        guard let meshData = await fetchMeshCentralData() else {
            message = "Failed to fetch MeshCentral data for Console."
            DiagnosticLogger.shared.appendError("Failed to fetch MeshCentral data for Console.")
            return
        }
        guard let url = URL(string: meshData.terminal) else {
            message = "Invalid URL for Console."
            DiagnosticLogger.shared.appendError("Invalid URL encountered in Console action.")
            return
        }
        DiagnosticLogger.shared.append("Initiating Console action.")
        let success = await UIApplication.shared.open(url)
        if !success {
            message = "Failed to open Console URL."
            DiagnosticLogger.shared.appendError("Failed to open URL during Console action.")
        } else {
            message = "Console URL opened successfully."
        }
    }
    
    var body: some View {
        let displayAgent = updatedAgent ?? agent
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Agent: \(displayAgent.hostname)")
                    .font(.title)
                Text("Operating System: \(displayAgent.operating_system)")
                    .font(.subheadline)
                // Added agent description here.
                if let description = displayAgent.description, !description.isEmpty {
                    Text("Description: \(description)")
                        .font(.subheadline)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("CPU: \(displayAgent.cpu_model.joined(separator: ", "))")
                    Text("GPU: \(displayAgent.graphics ?? "No GPU available")")
                    Text("Model: \(displayAgent.make_model ?? "Not available")")
                }
                .font(.subheadline)
                let lanIPText = displayAgent.local_ips?.ipv4Only().isEmpty == false ?
                    displayAgent.local_ips!.ipv4Only() : "No LAN IP available"
                Text("LAN IP: \(lanIPText) | Public IP: \(displayAgent.public_ip ?? "No IP available")")
                    .font(.subheadline)
                if let disks = displayAgent.physical_disks, !disks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Physical Disks:")
                            .font(.subheadline)
                        ForEach(disks, id: \.self) { disk in
                            Text("- \(disk)")
                                .font(.subheadline)
                        }
                    }
                } else {
                    Text("Physical Disks: N/A")
                        .font(.subheadline)
                }
                Text("Site: \(displayAgent.site_name ?? "Not available")")
                    .font(.subheadline)
                Text("Last Seen: \(formattedLastSeen(from: displayAgent.last_seen))")
                    .font(.subheadline)
                if isProcessing { ProgressView() }
                if let message = message {
                    Text(message)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }
                // Grid layout for action buttons.
                let columns = [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ]
                LazyVGrid(columns: columns, spacing: 10) {
                    Button("Reboot") {
                        Task {
                            DiagnosticLogger.shared.append("Reboot command initiated.")
                            await performAction(action: "reboot")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("Shutdown") {
                        showShutdownConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("Take Control") {
                        Task { await takeControl() }
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("Console") {
                        Task { await openConsole() }
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("Wake‑On‑Lan") {
                        Task { await performWakeOnLan() }
                    }
                    .buttonStyle(.borderedProminent)
                    
                    NavigationLink(destination: AgentHistoryView(agentId: agent.agent_id, baseURL: baseURL, apiKey: effectiveAPIKey)) {
                        Text("History")
                    }
                    .buttonStyle(.borderedProminent)
                    
                    NavigationLink(destination: AgentProcessesView(agentId: agent.agent_id, baseURL: baseURL, apiKey: effectiveAPIKey)) {
                        Text("Processes")
                    }
                    .buttonStyle(.borderedProminent)
                    
                    NavigationLink(destination: SendCommandView(agentId: agent.agent_id, baseURL: baseURL, apiKey: effectiveAPIKey)) {
                        Text("Send Command")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .alert("Confirm Shutdown", isPresented: $showShutdownConfirmation) {
                    Button("Shutdown", role: .destructive) {
                        Task {
                            DiagnosticLogger.shared.append("Shutdown command confirmed by user.")
                            await performAction(action: "shutdown")
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Are you sure you want to shutdown?")
                }
                Text("If the page does not load when using 'Take Control' or 'Console', tap 'Request Desktop' in Safari.")
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.top, 5)
            }
            .padding()
        }
        .onAppear {
            DiagnosticLogger.shared.append("AgentDetailView onAppear")
            Task { await fetchAgentDetail() }
        }
    }
}

// MARK: - SendCommandView

struct SendCommandView: View {
    let agentId: String
    let baseURL: String
    let apiKey: String
    
    @State private var command: String = ""
    @State private var selectedShell: String = "cmd" // "cmd" or "powershell"
    @State private var runAsUser: Bool = false
    @State private var timeout: String = "30"
    @State private var outputText: String = ""
    @State private var statusMessage: String? = nil
    @State private var isProcessing: Bool = false
    
    var effectiveAPIKey: String {
        return KeychainHelper.shared.getAPIKey() ?? apiKey
    }
    
    var body: some View {
        Form {
            Section(header: Text("Command Options")) {
                Picker("Shell", selection: $selectedShell) {
                    Text("CMD").tag("cmd")
                    Text("Powershell").tag("powershell")
                }
                .pickerStyle(SegmentedPickerStyle())
                
                HStack {
                    Text("Timeout:")
                    TextField("Timeout", text: $timeout)
                        .keyboardType(.numberPad)
                }
                
                Toggle("Run as user", isOn: $runAsUser)
                
                Button("Send") {
                    UIApplication.shared.dismissKeyboard()
                    Task { await sendCommand() }
                }
                .buttonStyle(.borderedProminent)
            }
            
            Section(header: Text("Command")) {
                TextEditor(text: $command)
                    .frame(minHeight: 150)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.5)))
            }
            
            Section(header:
                Group {
                    HStack {
                        Text("Output")
                        Spacer()
                        if let status = statusMessage {
                            Text(status)
                                .foregroundColor(status == "Command sent successfully!" ? .green : .red)
                        } else {
                            EmptyView()
                        }
                    }
                }
            ) {
                let processedOutput = outputText
                    .replacingOccurrences(of: "\\r", with: "")
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "/r", with: "")
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\"\"", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                TextEditor(text: .constant(processedOutput.isEmpty ? "No output" : processedOutput))
                    .frame(minHeight: 150)
                    .disabled(true)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.5)))
            }
        }
        .navigationTitle("Send Command")
    }
    
    @MainActor
    func sendCommand() async {
        guard let timeoutInt = Int(timeout) else {
            statusMessage = "Invalid timeout value"
            return
        }
        isProcessing = true
        outputText = ""
        statusMessage = nil
        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/\(agentId)/cmd/") else {
            statusMessage = "Invalid URL"
            isProcessing = false
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addDefaultHeaders(apiKey: effectiveAPIKey)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any?] = [
            "shell": selectedShell,
            "cmd": command,
            "timeout": timeoutInt,
            "custom_shell": nil,
            "run_as_user": runAsUser
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            statusMessage = "Error preparing request: \(error.localizedDescription)"
            isProcessing = false
            return
        }
        
        DiagnosticLogger.shared.logHTTPRequest(method: "POST", url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:])
        DiagnosticLogger.shared.append("Body: \(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(method: "POST", url: url.absoluteString, status: httpResponse.statusCode, data: data)
                if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 {
                    statusMessage = "Command sent successfully!"
                } else {
                    statusMessage = "HTTP Error: \(httpResponse.statusCode)"
                }
                outputText = String(data: data, encoding: .utf8) ?? ""
            }
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
            DiagnosticLogger.shared.appendError("Error sending command: \(error.localizedDescription)")
        }
        isProcessing = false
    }
}

// MARK: - AgentHistoryView

struct AgentHistoryView: View {
    let agentId: String
    let baseURL: String
    let apiKey: String
    
    @State private var historyRecords: [HistoryRecord] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    
    var effectiveAPIKey: String {
        return KeychainHelper.shared.getAPIKey() ?? apiKey
    }
    
    var body: some View {
        VStack {
            if isLoading {
                ProgressView("Loading history...")
                    .padding()
            } else if let errorMessage = errorMessage {
                Text("Error: \(errorMessage)")
                    .foregroundColor(.red)
                    .padding()
            } else if historyRecords.isEmpty {
                Text("No history records found.")
                    .padding()
            } else {
                List(historyRecords) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command: \(record.command)")
                            .font(.headline)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text("Time: \(record.time)")
                            .font(.subheadline)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text("Type: \(record.type)")
                            .font(.caption)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Text("User: \(record.username)")
                            .font(.caption)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        if let stdout = record.script_results?.stdout, !stdout.isEmpty {
                            let lines = stdout.components(separatedBy: "\n")
                            if lines.count > 300 {
                                Text("Output: \(lines.prefix(300).joined(separator: "\n"))")
                                    .font(.caption2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("Output too long. You can view the full text on your Tactical RMM Server.")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("Output: \(stdout)")
                                    .font(.caption2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Spacer()
        }
        .navigationTitle("Agent History")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await fetchHistory() }
        }
    }
    
    @MainActor
    func fetchHistory() async {
        isLoading = true
        errorMessage = nil
        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/\(agentId)/history/") else {
            errorMessage = "Invalid URL"
            DiagnosticLogger.shared.appendError("Invalid URL in Agent History.")
            isLoading = false
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addDefaultHeaders(apiKey: effectiveAPIKey)
        DiagnosticLogger.shared.logHTTPRequest(method: "GET", url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(method: "GET", url: url.absoluteString, status: httpResponse.statusCode, data: data)
                if httpResponse.statusCode != 200 {
                    errorMessage = "HTTP Error: \(httpResponse.statusCode)"
                    DiagnosticLogger.shared.appendError("HTTP Error \(httpResponse.statusCode) in Agent History.")
                    isLoading = false
                    return
                }
            }
            let decodedHistory = try JSONDecoder().decode([HistoryRecord].self, from: data)
            historyRecords = decodedHistory
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Error fetching Agent History: \(error.localizedDescription)")
        }
        isLoading = false
    }
}

// MARK: - AgentProcessesView

struct AgentProcessesView: View {
    let agentId: String
    let baseURL: String
    let apiKey: String

    @State private var processRecords: [ProcessRecord] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    
    @State private var showKillSheet: Bool = false
    @State private var pidToKill: String = ""
    @State private var killMessage: String? = nil
    
    @State private var searchQuery: String = ""
    @State private var appliedSearchQuery: String = ""
    
    // New state for the selected process.
    @State private var selectedProcess: ProcessRecord? = nil
    
    var effectiveAPIKey: String {
        return KeychainHelper.shared.getAPIKey() ?? apiKey
    }
    
    var displayedProcesses: [ProcessRecord] {
        if appliedSearchQuery.isEmpty {
            return processRecords
        } else {
            return processRecords.filter { $0.name.localizedCaseInsensitiveContains(appliedSearchQuery) }
        }
    }

    var body: some View {
        VStack {
            Button("Kill PID processes") {
                Task {
                    if let process = selectedProcess {
                        await killProcess(withPid: process.pid)
                    } else {
                        showKillSheet = true
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 10)
            .sheet(isPresented: $showKillSheet) {
                VStack(spacing: 20) {
                    Text("Enter PID to kill")
                        .font(.headline)
                    TextField("PID", text: $pidToKill)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .padding(.horizontal)
                    HStack {
                        Button("Cancel") {
                            showKillSheet = false
                            pidToKill = ""
                        }
                        .buttonStyle(.bordered)
                        Button("Confirm") {
                            Task {
                                if let pidInt = Int(pidToKill), pidInt > 0 {
                                    await killProcess(withPid: pidInt)
                                }
                                showKillSheet = false
                                pidToKill = ""
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
                .padding()
            }
            
            HStack {
                TextField("Search process name", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit {
                        appliedSearchQuery = searchQuery
                    }
            }
            .padding(.horizontal)
            
            if isLoading {
                ProgressView("Loading processes...")
                    .padding()
            } else if let errorMessage = errorMessage {
                Text("Error: \(errorMessage)")
                    .foregroundColor(.red)
                    .padding()
            } else if processRecords.isEmpty {
                Text("No processes found.")
                    .padding()
            } else {
                List(displayedProcesses) { process in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name: \(process.name)")
                            .font(.headline)
                        Text("PID: \(process.pid)")
                            .font(.subheadline)
                        Text("Memory (bytes): \(process.membytes)")
                            .font(.subheadline)
                        Text("Username: \(process.username)")
                            .font(.caption)
                        Text("CPU Percent: \(process.cpu_percent)")
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                    .background(selectedProcess?.id == process.id ? Color.blue.opacity(0.2) : Color.clear)
                    .cornerRadius(8)
                    .onTapGesture {
                        if selectedProcess?.id == process.id {
                            selectedProcess = nil
                        } else {
                            selectedProcess = process
                        }
                    }
                }
            }
            if let killMessage = killMessage {
                Text(killMessage)
                    .foregroundColor(killMessage.contains("killed") ? .green : .red)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            Spacer()
        }
        .navigationTitle("Agent Processes")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await fetchProcesses() }
        }
    }
    
    @MainActor
    func fetchProcesses() async {
        isLoading = true
        errorMessage = nil
        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/\(agentId)/processes/") else {
            errorMessage = "Invalid URL"
            DiagnosticLogger.shared.appendError("Invalid URL in fetching processes.")
            isLoading = false
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addDefaultHeaders(apiKey: effectiveAPIKey)
        DiagnosticLogger.shared.logHTTPRequest(method: "GET", url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(method: "GET", url: url.absoluteString, status: httpResponse.statusCode, data: data)
                if httpResponse.statusCode != 200 {
                    errorMessage = "HTTP Error: \(httpResponse.statusCode)"
                    DiagnosticLogger.shared.appendError("HTTP Error \(httpResponse.statusCode) in fetching processes.")
                    isLoading = false
                    return
                }
            }
            let decodedProcesses = try JSONDecoder().decode([ProcessRecord].self, from: data)
            processRecords = decodedProcesses
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Error fetching processes: \(error.localizedDescription)")
        }
        isLoading = false
    }
    
    @MainActor
    func killProcess(withPid pid: Int) async {
        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/\(agentId)/processes/\(pid)/") else {
            killMessage = "Invalid URL"
            DiagnosticLogger.shared.appendError("Invalid URL in kill process.")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.addDefaultHeaders(apiKey: effectiveAPIKey)
        DiagnosticLogger.shared.logHTTPRequest(method: "DELETE", url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(method: "DELETE", url: url.absoluteString, status: httpResponse.statusCode, data: Data())
                if httpResponse.statusCode == 200 {
                    killMessage = "Process \(pid) killed successfully!"
                    selectedProcess = nil
                    await fetchProcesses()
                } else {
                    killMessage = "Failed to kill process \(pid)."
                    DiagnosticLogger.shared.appendError("Failed to kill process \(pid), HTTP status \(httpResponse.statusCode).")
                }
            }
        } catch {
            killMessage = "Error: \(error.localizedDescription)"
            DiagnosticLogger.shared.appendError("Error in kill process: \(error.localizedDescription)")
        }
    }
}
