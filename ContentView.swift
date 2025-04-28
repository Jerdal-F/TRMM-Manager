import SwiftUI
import SwiftData
import Security
import LocalAuthentication

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
    
    func maskAPIKey(_ key: String) -> String {
        let length = key.count
        if length <= 8 {
            return String(repeating: "X", count: length)
        }
        let first = key.prefix(4)
        let last = key.suffix(4)
        return "\(first)XXXXXXXXXXXXXX\(last)"
    }
    
    func logHTTPResponse(method: String, url: String, status: Int, data: Data?) {
        let responseBody: String
        if let data = data, let responseString = String(data: data, encoding: .utf8) {
            responseBody = responseString.count > 200 ? String(responseString.prefix(200)) + "..." : responseString
        } else {
            responseBody = "No response body."
        }
        append("HTTP Response: \(status) for \(method) \(url). Response Body: \(responseBody)")
    }
    
    func appendWarning(_ message: String) {
        append("WARNING: \(message)")
    }
    
    func appendError(_ message: String) {
        append("ERROR: \(message)")
    }
    
    func getLogFileURL() -> URL? {
        return logFileURL
    }
    
    private func sanitizeHeaders(_ headers: [String: String]) -> [String: String] {
        var sanitized = headers
        if sanitized["X-API-KEY"] != nil {
            sanitized["X-API-KEY"] = "[REDACTED]"
        }
        return sanitized
    }
    
    func logHTTPRequest(method: String, url: String, headers: [String: String]) {
        let sanitized = sanitizeHeaders(headers)
        append("HTTP Request: \(method) \(url) Headers: \(sanitized)")
    }
}

// MARK: - Keychain Helper

/// Caches the API key in RAM after the first read, to avoid
/// hitting the Keychain (and repeated logs) every time.
final class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    private let service = "jerdal.TacticalRMM-Manager"

    /// In-memory cache of the API key
    private var cachedAPIKey: String?

    // MARK: — Generic Save/Read/Delete

    func save(_ data: Data, for account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String:   data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        DiagnosticLogger.shared.append("Keychain save status for \(account): \(status)")
    }

    func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return data
        }
        return nil
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: — API Key Convenience

    /// Save the API Key both to Keychain *and* to our in-memory cache.
    func saveAPIKey(_ apiKey: String) {
        // cache in RAM
        cachedAPIKey = apiKey
        DiagnosticLogger.shared.append("Saving API Key: \(DiagnosticLogger.shared.maskAPIKey(apiKey))")

        // persist to Keychain
        if let data = apiKey.data(using: .utf8) {
            save(data, for: "apiKey")
        }
    }

    /// Return the API Key, reading from cache if available;
    /// otherwise, pull once from the Keychain and cache it.
    func getAPIKey() -> String? {
        // 1) If key is cached, no Keychain hit:
        if let key = cachedAPIKey {
            DiagnosticLogger.shared.append("Getting cachedAPIKey")
            return key
        }

        // 2) Otherwise, read from Keychain:
        if let data = read(account: "apiKey"),
           let key = String(data: data, encoding: .utf8) {
            // cache & log only once
            cachedAPIKey = key
            DiagnosticLogger.shared.append("Retrieved API Key from Keychain: \(DiagnosticLogger.shared.maskAPIKey(key))")
            return key
        }

        return nil
    }

    /// Wipe both the in-memory cache *and* the Keychain entry.
    func deleteAPIKey() {
        // clear RAM
        cachedAPIKey = nil

        // clear Keychain
        delete(account: "apiKey")

        DiagnosticLogger.shared.append("Deleted API Key from Keychain and cleared cache")
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
    let custom_fields: [CustomField]?
    let serial_number: String?
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

struct ProcessRecord: Identifiable, Decodable {
    let id: Int
    let name: String
    let pid: Int
    let membytes: Int
    let username: String
    let cpu_percent: String
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

// New Models for Installer

struct Site: Identifiable, Decodable {
    let id: Int
    let name: String
}

struct ClientModel: Identifiable, Decodable {
    let id: Int
    let name: String
    let sites: [Site]
}

// MARK: - ContentView

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase)   private var scenePhase
    @Query private var settingsList: [RMMSettings]

    @AppStorage("hideInstall") private var hideInstall: Bool = false
    @AppStorage("useFaceID")    private var useFaceID:    Bool = false

    @State private var didAuthenticate:      Bool    = false
    @State private var isAuthenticating:     Bool    = false
    @State private var baseURLText:          String  = ""
    @State private var apiKeyText:           String  = ""
    @State private var showSavedAlert:       Bool    = false
    @State private var showGuideAlert:       Bool    = false
    @State private var showSettings:         Bool    = false
    @State private var agents:               [Agent] = []
    @State private var isLoading:            Bool    = false
    @State private var errorMessage:         String? = nil
    @State private var showDiagnosticAlert:  Bool    = false
    @State private var showLogShareSheet:    Bool    = false
    @FocusState private var isInputActive:   Bool

    @State private var searchText:           String = ""
    @State private var appliedSearchText:    String = ""
    @State private var showSearch:           Bool   = false
    @FocusState private var searchFieldIsFocused: Bool
    @State private var showRecoveryAlert = false

    var filteredAgents: [Agent] {
        if appliedSearchText.isEmpty {
            return agents
        } else {
            return agents.filter {
                $0.hostname.localizedCaseInsensitiveContains(appliedSearchText) ||
                $0.operating_system.localizedCaseInsensitiveContains(appliedSearchText)
            }
        }
    }

    var body: some View {
        ZStack {
            NavigationView {
                Form {
                    // MARK: – API Settings
                    Section(header: Text("API Settings"),
                            footer: Text("Note: You might experience issues if you have a large number of agents due to hardware limitations")) {
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
                        } else if baseURLText.removingTrailingSlash().lowercased() == "demo"
                                  && apiKeyText.lowercased() == "demo" {
                            Button("Demo Mode") {
                                DiagnosticLogger.shared.append("Demo mode login triggered.")
                                isInputActive = false
                                loadDemoAgents()
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.vertical, 8)
                        } else if let saved = settingsList.first,
                                  saved.baseURL == baseURLText,
                                  KeychainHelper.shared.getAPIKey() == apiKeyText {
                            HStack(spacing: 12) {
                                Button("Login") {
                                    DiagnosticLogger.shared.append("Login tapped.")
                                    isInputActive = false
                                    Task { await fetchAgents(using: saved) }
                                }
                                .buttonStyle(.borderedProminent)

                                if !hideInstall {
                                    NavigationLink("Install New Agent",
                                                   destination: InstallAgentView(
                                                       baseURL: baseURLText,
                                                       apiKey: apiKeyText
                                                   ))
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding(.vertical, 8)
                        } else {
                            Button("Save & Login") {
                                DiagnosticLogger.shared.append("Save & Login tapped.")
                                isInputActive = false
                                Task { await updateSettingsAndFetch() }
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.vertical, 8)
                        }
                    }

                    // MARK: – Agents List
                    Section(header:
                        HStack {
                            Text("Agents").font(.headline)
                            Spacer()
                            if showSearch {
                                TextField("Search agents", text: $searchText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                                    .disableAutocorrection(true)
                                    .focused($searchFieldIsFocused)
                                    .submitLabel(.search)
                                    .onSubmit { appliedSearchText = searchText }
                            } else {
                                Button {
                                    withAnimation {
                                        showSearch = true
                                        searchFieldIsFocused = true
                                    }
                                } label: {
                                    Image(systemName: "magnifyingglass")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .transaction { $0.animation = nil }
                    ) {
                        if isLoading {
                            ProgressView("Loading agents...")
                        }
                        if let error = errorMessage {
                            Text("Error: \(error)")
                                .foregroundColor(.red)
                        }
                        ForEach(filteredAgents) { agent in
                            NavigationLink(destination:
                                AgentDetailView(
                                    agent: agent,
                                    baseURL: baseURLText,
                                    apiKey: apiKeyText
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(agent.hostname).font(.headline)
                                    Text(agent.operating_system).font(.subheadline)
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
                                    if let ip = agent.public_ip {
                                        Text("Public IP: \(ip)").font(.caption)
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
                        message: Text("Seems like you're new here. We recommend reading the guide."),
                        primaryButton: .default(Text("Read Guide")) {
                            if let url = URL(string: "https://github.com/Jerdal-F/TacticalRMM-Manager/blob/main/README.md") {
                                UIApplication.shared.open(url)
                            }
                        },
                        secondaryButton: .cancel()
                    )
                }
                .alert("Diagnostics", isPresented: $showDiagnosticAlert) {
                    Button("Save", role: .destructive) { showLogShareSheet = true }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Export diagnostics log? It may include sensitive information.")
                }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack {
                            Text("Tactical RMM").font(.headline)
                            Text("Agent Manager").font(.subheadline)
                        }
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 2, maximumDistance: 50) { pressing in
                            DiagnosticLogger.shared.append("Long press: \(pressing)")
                        } perform: {
                            DiagnosticLogger.shared.append("Long‑pressed for diagnostics.")
                            showDiagnosticAlert = true
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showSettings = true }
                    label: { Image(systemName: "gearshape") }
                    }
                }
                .onAppear {
                    DiagnosticLogger.shared.append("ContentView onAppear")
                    if !useFaceID {
                        loadInitialSettings()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background, .inactive:
                        didAuthenticate = false

                    case .active:
                        guard useFaceID, !didAuthenticate else { return }

                        // If neither FaceID nor passcode is available, show reset UI instead of trying to auth
                        if !authAvailable {
                            showRecoveryAlert = true
                            return
                        }

                        // Otherwise do the normal authenticate → load or suspend
                        isAuthenticating = true
                        authenticateBiometrics { success in
                            isAuthenticating = false
                            if success {
                                didAuthenticate = true
                                loadInitialSettings()
                            } else {
                                UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
                            }
                        }

                    @unknown default:
                        break
                    }
                }

                .onChange(of: useFaceID) { oldValue, newValue in
                    if newValue {
                        isAuthenticating = true
                        authenticateBiometrics { success in
                            isAuthenticating = false
                            if !success {
                                useFaceID = false
                            }
                        }
                    }
                }
                .alert("Settings Saved", isPresented: $showSavedAlert) {
                    Button("OK", role: .cancel) {}
                }
            }
            .navigationViewStyle(.stack)

            // Block interaction until FaceID completes with recovery alert
            if useFaceID && !didAuthenticate {
                ZStack {
                    // Full-screen blur material
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()

                    // Semi-transparent black overlay on top of the blur
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                    
                    ProgressView(isAuthenticating ? "Authenticating with FaceID…" : "Please wait…")
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                }
                // When this view appears, if auth is impossible, force recovery
                .onAppear {
                    if !authAvailable {
                        showRecoveryAlert = true
                    }
                }
                // Recovery alert
                .alert(isPresented: $showRecoveryAlert) {
                                Alert(
                                    title: Text("Security Reset Required"),
                                    message: Text("""
                                        You’ve disabled both Face ID and device passcode while having the FaceID app lock enabled. \
                                        For security, you must clear all saved settings and API keys. \
                                        Tap “Clear App Data” to reset.
                                        """),
                                    // This is a single destructive “dismiss” button—no Cancel is injected
                                    dismissButton: .destructive(
                                        Text("Clear App Data"),
                                        action: clearAppData
                                    )
                                )
                            }
                        }
                    }
                    // Only allow the Settings sheet to appear when not locked
                    .sheet(isPresented: Binding(
                        get:  { showSettings && !(useFaceID && !didAuthenticate) },
                        set:  { showSettings = $0 }
                    )) {
                        SettingsView()
                    }
                    // Share & settings sheets
                    .sheet(isPresented: $showLogShareSheet) {
                        if let url = DiagnosticLogger.shared.getLogFileURL() {
                            ActivityView(activityItems: [url])
                        } else {
                            Text("No diagnostics log available.")
                        }
                    }
                }

    // MARK: – Helper Methods

    private func loadInitialSettings() {
        if let saved = settingsList.first {
            baseURLText = saved.baseURL
            apiKeyText   = KeychainHelper.shared.getAPIKey() ?? ""
        }
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            showGuideAlert = true
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        }
    }

    private func authenticateBiometrics(completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?

        // Now require deviceOwnerAuthentication (biometrics + passcode)
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Neither biometrics nor passcode available → block access
            completion(false)
            return
        }

        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Unlock Tactical RMM Agent Manager"
        ) { success, _ in
            DispatchQueue.main.async {
                completion(success)
            }
        }
    }
    
    private var authAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
// Fredrik Jerdal 2025
    @MainActor
    private func clearAppData() {
        // 1) Remove API key from both Keychain and cache
        KeychainHelper.shared.deleteAPIKey()
        let apiKeyStillThere = KeychainHelper.shared.getAPIKey() != nil

        // 2) Delete persisted SwiftData settings
        for setting in settingsList {
            modelContext.delete(setting)
        }
        var coreDataError: Error?
        do {
            try modelContext.save()
        } catch {
            coreDataError = error
            DiagnosticLogger.shared.appendError("Error clearing settings: \(error)")
        }

        // 3) Reset any @AppStorage flags
        UserDefaults.standard.removeObject(forKey: "hasLaunchedBefore")
        UserDefaults.standard.removeObject(forKey: "hideInstall")

        // 4) Verify everything is gone
        let userDefaultsCleared =
            UserDefaults.standard.object(forKey: "hasLaunchedBefore") == nil &&
            UserDefaults.standard.object(forKey: "hideInstall") == nil

        let coreDataCleared = settingsList.isEmpty && coreDataError == nil

        // 5) Only if all three areas are clean, disable FaceID lock
        if !apiKeyStillThere && coreDataCleared && userDefaultsCleared {
            useFaceID = false
        } else {
            if apiKeyStillThere {
                DiagnosticLogger.shared.appendWarning("API Key still present after deletion.")
            }
            if !coreDataCleared {
                DiagnosticLogger.shared.appendWarning("SwiftData settings still exist after deletion.")
            }
            if !userDefaultsCleared {
                DiagnosticLogger.shared.appendWarning("AppStorage flags not fully cleared.")
            }
        }

        // 6) Clear UI state and force a fresh launch
        baseURLText = ""
        apiKeyText = ""
        UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
    }

    @MainActor
    private func updateSettingsAndFetch() async {
        DiagnosticLogger.shared.append("updateSettingsAndFetch started")
        baseURLText = baseURLText.removingTrailingSlash()
        if baseURLText.lowercased() != "demo"
           && !baseURLText.lowercased().hasPrefix("http://")
           && !baseURLText.lowercased().hasPrefix("https://") {
            baseURLText = "https://" + baseURLText
        }
        if let saved = settingsList.first {
            saved.baseURL = baseURLText
            KeychainHelper.shared.saveAPIKey(apiKeyText)
            await saveSettingsAndFetch(settings: saved)
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
        request.addDefaultHeaders(apiKey: KeychainHelper.shared.getAPIKey() ?? "")
        DiagnosticLogger.shared.logHTTPRequest(
            method: "GET",
            url: url.absoluteString,
            headers: request.allHTTPHeaderFields ?? [:]
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(
                    method: "GET",
                    url: url.absoluteString,
                    status: http.statusCode,
                    data: data
                )
                switch http.statusCode {
                case 200:
                    agents = try JSONDecoder().decode([Agent].self, from: data)
                    DiagnosticLogger.shared.append("Fetched agents: \(agents.count)")
                case 401:
                    errorMessage = "Invalid API Key."
                    DiagnosticLogger.shared.appendError("HTTP 401 during fetch.")
                default:
                    errorMessage = "HTTP \(http.statusCode)"
                    DiagnosticLogger.shared.appendError("HTTP \(http.statusCode) during fetch.")
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Error fetching agents: \(error.localizedDescription)")
        }
        isLoading = false
    }

    private func loadDemoAgents() {
        DiagnosticLogger.shared.append("Loading demo agents.")
        agents = [
            Agent(
                agent_id: "demo1",
                hostname: "Demo1",
                operating_system: "iOS Demo OS",
                description: "Demo agent.",
                cpu_model: ["Demo CPU"],
                public_ip: "192.0.2.1",
                local_ips: "10.0.0.1",
                graphics: "Demo GPU",
                make_model: "Demo Model",
                status: "online",
                site_name: "Demo Site",
                last_seen: ISO8601DateFormatter().string(from: Date()),
                physical_disks: ["Demo Disk1"],
                custom_fields: [],
                serial_number: "Demo Serial 1"
            ),
            Agent(
                agent_id: "demo2",
                hostname: "Demo2",
                operating_system: "iOS Demo OS",
                description: "Demo agent 2.",
                cpu_model: ["Demo CPU"],
                public_ip: "192.0.2.2",
                local_ips: "10.0.0.2",
                graphics: "Demo GPU",
                make_model: "Demo Model",
                status: "offline",
                site_name: "Demo Site",
                last_seen: ISO8601DateFormatter().string(from: Date()),
                physical_disks: ["Demo Disk2"],
                custom_fields: [],
                serial_number: "Demo Serial2"
            )
        ]
    }
}


// MARK: - SettingsView

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hideInstall") var hideInstall: Bool = false
    @AppStorage("useFaceID") var useFaceID: Bool = false

    private var authAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Form {
                    Toggle("Hide install agent button", isOn: $hideInstall)

                    Toggle("Face ID App Lock", isOn: $useFaceID)
                        .disabled(!authAvailable)
                        .overlay(
                            Group {
                                if !authAvailable {
                                    Text("Requires at least a device passcode or biometric setup")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(.top, 4)
                                }
                            },
                            alignment: .bottomLeading
                        )
                }

                Spacer()

                // Guide button at bottom
                Button(action: {
                    guard let url = URL(string: "https://github.com/Jerdal-F/TacticalRMM-Manager")
                    else { return }
                    UIApplication.shared.open(url)
                }) {
                    Label("Guide", systemImage: "globe")
                        .frame(maxWidth: .infinity, minHeight: 10)
                        .padding()
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .padding(.horizontal)
                .padding(.bottom, 20)
                
                // Donate button
                Button(action: {
                    guard let url = URL(string: "https://buymeacoffee.com/jerdal")
                    else { return }
                    UIApplication.shared.open(url)
                }) {
                    Label("Donate", systemImage: "dollarsign.circle")
                        .frame(maxWidth: .infinity, minHeight: 10)
                        .padding()
                    
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .padding(.horizontal)
                .padding(.bottom, 20)
                
                // Footer
                Text("This app is an independent project and is not made by or affiliated with Tactical RMM/AmidaWare.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 20)
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}




// MARK: - InstallAgentView

struct InstallAgentView: View {
    let baseURL: String
    let apiKey: String

    @State private var clients: [ClientModel] = []
    @State private var selectedClientId: Int?
    @State private var sites: [Site] = []
    @State private var selectedSiteId: Int?
    @State private var agentType: String = "server" {
        didSet {
            // Reset power toggle whenever switching back to Server
            if agentType == "server" {
                power = false
            }
        }
    }
    @State private var power: Bool = false
    @State private var rdp: Bool = false
    @State private var ping: Bool = false
    @State private var arch: String = "amd64"
    @State private var expires: String = "24"
    @State private var fileName: String = "trmm-installer.exe"
    @State private var isLoadingClients = false
    @State private var errorMessage: String?
    @State private var isGenerating = false
    @State private var installerURL: URL?
    @State private var showShareSheet = false

    var body: some View {
        ZStack {
            Form {
                if isLoadingClients {
                    ProgressView("Loading clients...")
                } else if let errorMessage = errorMessage {
                    Text("Error: \(errorMessage)")
                        .foregroundColor(.red)
                } else {
                    Section(header: Text("Client & Site")) {
                        Picker("Client", selection: $selectedClientId) {
                            Text("Select...").tag(Int?.none)
                            ForEach(clients) { client in
                                Text(client.name).tag(Int?(client.id))
                            }
                        }
                        .onChange(of: selectedClientId) { old, new in
                            if let id = new, let client = clients.first(where: { $0.id == id }) {
                                sites = client.sites
                                selectedSiteId = nil
                            }
                        }

                        Picker("Site", selection: $selectedSiteId) {
                            Text("Select...").tag(Int?.none)
                            ForEach(sites) { site in
                                Text(site.name).tag(Int?(site.id))
                            }
                        }
                    }

                    Section(header: Text("Settings")) {
                        Picker("Agent Type", selection: $agentType) {
                            Text("Server").tag("server")
                            Text("Workstation").tag("workstation")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: agentType) {
                            if agentType == "server" {
                                power = false
                                print("Switched to Server → power reset")
                            }
                        }


                        
                        Picker("Architecture", selection: $arch) {
                            Text("64 bit").tag("amd64")
                            Text("32 bit").tag("386")
                        }
                        .pickerStyle(SegmentedPickerStyle())

                        Toggle("Disable sleep/hibernate", isOn: $power)
                            .disabled(agentType == "server")
                            .opacity(agentType == "server" ? 0.5 : 1.0)

                        Toggle("Enable RDP", isOn: $rdp)
                        Toggle("Enable Ping", isOn: $ping)

                        

                        HStack {
                            Text("Expires (hrs)")
                            TextField("Hours", text: $expires)
                                .keyboardType(.numberPad)
                                .frame(width: 60)
                        }
                    }

                    Section {
                        Button("Download Installer") {
                            Task { await generateInstaller() }
                        }
                        .disabled(isGenerating || selectedClientId == nil || selectedSiteId == nil)
                    }
                }
            }
            .navigationTitle("Install Windows Agent")
            .task { await fetchClients() }
            .sheet(isPresented: $showShareSheet) {
                if let url = installerURL {
                    ActivityView(activityItems: [url])
                }
            }

            if isGenerating {
                Color.black.opacity(0.3).ignoresSafeArea()
                ProgressView("Generating installer…")
                    .padding()
                    .background(.regularMaterial)
                    .cornerRadius(8)
            }
        }
    }

    func fetchClients() async {
        isLoadingClients = true
        errorMessage = nil
        let sanitized = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitized)/clients/") else {
            errorMessage = "Invalid URL"
            isLoadingClients = false
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addDefaultHeaders(apiKey: KeychainHelper.shared.getAPIKey() ?? apiKey)
        DiagnosticLogger.shared.logHTTPRequest(method: "GET", url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let resp = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(method: "GET", url: url.absoluteString, status: resp.statusCode, data: data)
                guard resp.statusCode == 200 else {
                    errorMessage = "HTTP Error: \(resp.statusCode)"
                    isLoadingClients = false
                    return
                }
            }
            clients = try JSONDecoder().decode([ClientModel].self, from: data)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingClients = false
    }

    func generateInstaller() async {
        guard let client = selectedClientId,
              let site = selectedSiteId,
              let expiresInt = Int(expires) else { return }
        isGenerating = true
        let sanitized = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitized)/agents/installer/") else {
            isGenerating = false
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addDefaultHeaders(apiKey: KeychainHelper.shared.getAPIKey() ?? apiKey)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "installMethod": "exe",
            "client": client,
            "site": site,
            "expires": expiresInt,
            "agenttype": agentType,
            "power": power ? 1 : 0,
            "rdp": rdp ? 1 : 0,
            "ping": ping ? 1 : 0,
            "goarch": arch,
            "api": "\(sanitized)",
            "fileName": fileName,
            "plat": "windows"
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            DiagnosticLogger.shared.logHTTPRequest(method: "POST", url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:])
            let (data, response) = try await URLSession.shared.data(for: request)
            if let resp = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(method: "POST", url: url.absoluteString, status: resp.statusCode, data: data)
                guard resp.statusCode == 200 else {
                    isGenerating = false
                    return
                }
            }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try data.write(to: tempURL)
            installerURL = tempURL
            showShareSheet = true
        } catch {
            DiagnosticLogger.shared.appendError("Error generating installer: \(error.localizedDescription)")
        }
        isGenerating = false
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
    @State private var showRebootConfirmation: Bool = false
    
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
        // Compute the serial to show:
        let serialToShow =
            updatedAgent?.serial_number  // freshest value, if present
            ?? agent.serial_number       // else whatever we got from the list
            ?? ""                        // else empty
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Agent: \(displayAgent.hostname)")
                    .font(.title)
                    .textSelection(.enabled)
                Text("Operating System: \(displayAgent.operating_system)")
                    .font(.subheadline)
                    .textSelection(.enabled)
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
                .textSelection(.enabled)
                let lanIPText = displayAgent.local_ips?.ipv4Only().isEmpty == false ?
                    displayAgent.local_ips!.ipv4Only() : "No LAN IP available"
                Text("LAN IP: \(lanIPText) | Public IP: \(displayAgent.public_ip ?? "No IP available")")
                    .font(.subheadline)
                    .textSelection(.enabled)
                if let disks = displayAgent.physical_disks, !disks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Physical Disks:")
                            .font(.subheadline)
                            .textSelection(.enabled)
                        ForEach(disks, id: \.self) { disk in
                            Text("- \(disk)")
                                .font(.subheadline)
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    Text("Physical Disks: N/A")
                        .font(.subheadline)
                }
                Text("Site: \(displayAgent.site_name ?? "Not available")")
                    .font(.subheadline)
                Text("Serial Number: \(serialToShow.isEmpty ? "N/A" : serialToShow)")
                    .font(.subheadline)
                    .textSelection(.enabled)
                Text("Last Seen: \(formattedLastSeen(from: displayAgent.last_seen))")
                    .font(.subheadline)
                if isProcessing { ProgressView() }
                if let message = message {
                    Text(message)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }
                let columns = [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ]
                LazyVGrid(columns: columns, spacing: 10) {
                    Button("Reboot") {
                        showRebootConfirmation = true
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    
                    Button("Shutdown") {
                        showShutdownConfirmation = true
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    
                    Button("Take Control") {
                        Task { await takeControl() }
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    
                    Button("Console") {
                        Task { await openConsole() }
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    
                    Button("Wake‑On‑Lan") {
                        Task { await performWakeOnLan() }
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    
                    NavigationLink(destination: AgentProcessesView(agentId: agent.agent_id, baseURL: baseURL, apiKey: effectiveAPIKey)) {
                        Text("Processes")
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    
                    NavigationLink(destination: SendCommandView(agentId: agent.agent_id, baseURL: baseURL, apiKey: effectiveAPIKey)) {
                        Text("Send Command")
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    
                    NavigationLink(destination: AgentNotesView(agentId: agent.agent_id, baseURL: baseURL, apiKey: effectiveAPIKey)) {
                        Text("Notes")
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    
                    NavigationLink(destination: AgentTasksView(agentId: agent.agent_id, baseURL: baseURL, apiKey: effectiveAPIKey)) {
                        Text("Tasks")
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    
                    let nonEmptyCustomFields = displayAgent.custom_fields?
                        .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        ?? []

                    NavigationLink(
                        destination: AgentCustomFieldsView(customFields: nonEmptyCustomFields)
                    ) {
                        Text("Custom Fields")
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.borderedProminent)
                    .disabled(nonEmptyCustomFields.isEmpty)
                    .opacity(nonEmptyCustomFields.isEmpty ? 0.5 : 1.0)


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
                .alert("Confirm Reboot", isPresented: $showRebootConfirmation) {
                    Button("Reboot", role: .destructive) {
                        Task {
                            DiagnosticLogger.shared.append("Reboot command confirmed by user.")
                            await performAction(action: "reboot")
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Are you sure you want to reboot?")
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
    @State private var selectedShell: String = "cmd"
    @State private var runAsUser: Bool = false
    @State private var timeout: String = "30"
    @State private var outputText: String = ""
    @State private var statusMessage: String? = nil
    @State private var isProcessing: Bool = false
    
    var effectiveAPIKey: String {
        return KeychainHelper.shared.getAPIKey() ?? apiKey
    }
    
    var body: some View {
        ZStack {
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
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.gray.opacity(0.5))
                        )
                }
                
                Section(header:
                    HStack {
                        Text("Output")
                        Spacer()
                        if let status = statusMessage {
                            Text(status)
                                .foregroundColor(status == "Command sent successfully!" ? .green : .red)
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
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.gray.opacity(0.5))
                        )
                }
            }
            
            if isProcessing {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    ProgressView("Sending Command...")
                        .progressViewStyle(CircularProgressViewStyle())
                        .tint(.white)
                        .padding()
                        .background(Color.gray)
                        .cornerRadius(10)
                }
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

// MARK: - AgentProcessesView

struct AgentProcessesView: View {
    let agentId: String
    let baseURL: String
    let apiKey: String

    private let uniformButtonWidth: CGFloat = 150

    @State private var processRecords: [ProcessRecord] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil

    @State private var showKillSheet: Bool = false
    @State private var pidToKill: String = ""
    @State private var killMessage: String? = nil

    @State private var searchQuery: String = ""
    @State private var appliedSearchQuery: String = ""

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
            HStack {
                TextField("Search process name", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .submitLabel(.search)
                    .onSubmit {
                        appliedSearchQuery = searchQuery
                    }
            }
            .padding(.horizontal)
            .padding(.top, 8)

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
            .frame(width: uniformButtonWidth)
            .padding()
            .sheet(isPresented: $showKillSheet) {
                VStack(spacing: 20) {
                    Text("Enter PID to kill")
                        .font(.headline)
                    TextField("PID", text: $pidToKill)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .padding(.horizontal)
                    HStack(spacing: 16) {
                        Button("Cancel") {
                            showKillSheet = false
                            pidToKill = ""
                        }
                        .frame(width: uniformButtonWidth)
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
                        .frame(width: uniformButtonWidth)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                    .padding(.horizontal)
                }
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

// MARK: - AgentNotesView

struct AgentNotesView: View {
    let agentId: String
    let baseURL: String
    let apiKey: String

    @State private var notes: [Note] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil

    var effectiveAPIKey: String {
        return KeychainHelper.shared.getAPIKey() ?? apiKey
    }

    var body: some View {
        VStack {
            if isLoading {
                ProgressView("Loading notes...")
                    .padding()
            } else if let errorMessage = errorMessage {
                Text("Error: \(errorMessage)")
                    .foregroundColor(.red)
                    .padding()
            } else if notes.isEmpty {
                Text("No notes found.")
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(notes) { note in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Note:")
                                    .font(.headline)
                                Text(note.note)
                                Text("By: \(note.username)")
                                    .font(.caption)
                                Text("Time: \(note.entry_time)")
                                    .font(.caption)
                            }
                            .padding()
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(8)
                        }
                    }
                    .padding()
                }
            }
            Spacer()
        }
        .navigationTitle("Agent Notes")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await fetchNotes() }
        }
    }

    @MainActor
    func fetchNotes() async {
        isLoading = true
        errorMessage = nil
        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/\(agentId)/notes/") else {
            errorMessage = "Invalid URL"
            DiagnosticLogger.shared.appendError("Invalid URL in fetching notes.")
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
                    DiagnosticLogger.shared.appendError("HTTP Error \(httpResponse.statusCode) in fetching notes.")
                    isLoading = false
                    return
                }
            }
            let decodedNotes = try JSONDecoder().decode([Note].self, from: data)
            notes = decodedNotes
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Error fetching notes: \(error.localizedDescription)")
        }
        isLoading = false
    }
}

// MARK: - AgentTasksView

struct AgentTasksView: View {
    let agentId: String
    let baseURL: String
    let apiKey: String

    @State private var tasks: [AgentTask] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil

    var effectiveAPIKey: String {
        return KeychainHelper.shared.getAPIKey() ?? apiKey
    }

    private func truncatedResult(_ result: String) -> String {
        let words = result.split(separator: " ")
        if words.count > 800 {
            let truncated = words.prefix(800).joined(separator: " ")
            return "\(truncated)... \nFull result available on the RMM Server."
        }
        return result
    }

    var body: some View {
        VStack {
            if isLoading {
                ProgressView("Loading tasks...")
                    .padding()
            } else if let errorMessage = errorMessage {
                Text("Error: \(errorMessage)")
                    .foregroundColor(.red)
                    .padding()
            } else if tasks.isEmpty {
                Text("No tasks found.")
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(tasks) { task in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(task.name)
                                    .font(.headline)
                                Text("Schedule: \(task.schedule)")
                                Text("Run Time: \(task.run_time_date)")
                                Text("Created by: \(task.created_by) at \(task.created_time)")
                                    .font(.caption)
                                if let result = task.task_result {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Result:")
                                            .font(.subheadline)
                                        Text(truncatedResult(result.stdout))
                                            .font(.caption)
                                    }
                                }
                                if let actions = task.actions, !actions.isEmpty {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Actions:")
                                            .font(.subheadline)
                                        ForEach(actions, id: \.name) { action in
                                            Text("- \(action.name) (\(action.type))")
                                                .font(.caption)
                                        }
                                    }
                                }
                            }
                            .padding()
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(8)
                        }
                    }
                    .padding()
                }
            }
            Spacer()
        }
        .navigationTitle("Agent Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await fetchTasks() }
        }
    }

    @MainActor
    func fetchTasks() async {
        isLoading = true
        errorMessage = nil
        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/\(agentId)/tasks/") else {
            errorMessage = "Invalid URL"
            DiagnosticLogger.shared.appendError("Invalid URL in fetching tasks.")
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
                    DiagnosticLogger.shared.appendError("HTTP Error \(httpResponse.statusCode) in fetching tasks.")
                    isLoading = false
                    return
                }
            }
            let decodedTasks = try JSONDecoder().decode([AgentTask].self, from: data)
            tasks = decodedTasks
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Error fetching tasks: \(error.localizedDescription)")
        }
        isLoading = false
    }
}

// MARK: – CustomField Model
struct CustomField: Identifiable, Decodable {
    let id: Int
    let field: Int
    let agent: Int
    let value: String
}

// MARK: – AgentCustomFieldsView
struct AgentCustomFieldsView: View {
    let customFields: [CustomField]

    var body: some View {
        VStack {
            if customFields.isEmpty {
                Text("No custom fields found.")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(customFields) { field in
                            VStack(alignment: .leading, spacing: 6) {
                                // you can still show the record‐ID if you want:
                                Text("Record ID: \(field.id)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text(field.value)
                                    .font(.body)
                                    .textSelection(.enabled)  // let the user copy
                            }
                            .padding()
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(8)
                        }
                    }
                    .padding()
                }
            }
            Spacer()
        }
        .navigationTitle("Custom Fields")
        .navigationBarTitleDisplayMode(.inline)
    }
}
