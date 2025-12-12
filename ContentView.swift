import SwiftUI
import SwiftData
import Security
import LocalAuthentication
import UIKit
import StoreKit

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
        logDeviceInfo()
    }

    /// Logs basic device information at startup
    private func logDeviceInfo() {
        let device = UIDevice.current
        let processInfo = ProcessInfo.processInfo
        append("Device Version: \(device.name)")
        append("OS Version: \(device.systemName) \(device.systemVersion)")
        append("Model: \(device.model)")
        append("Identifier: \(device.identifierForVendor?.uuidString ?? "N/A")")
        append("Screen: \(UIScreen.main.bounds.width)x\(UIScreen.main.bounds.height) @\(UIScreen.main.scale)x")
        append("CPU Cores: \(processInfo.processorCount)")
        append("Physical Memory: \(processInfo.physicalMemory / 1_048_576) MB")
        if let info = Bundle.main.infoDictionary {
                let version = info["CFBundleShortVersionString"] as? String ?? "N/A"
                let build   = info["CFBundleVersion"]             as? String ?? "N/A"
                append("App Version: \(version) (build \(build))")
            }
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
            // Do not truncate /agents responses; keep others concise
            if url.contains("/agents/") {
                responseBody = responseString
            } else {
                responseBody = responseString.count > 200
                    ? String(responseString.prefix(200)) + "..."
                    : responseString
            }
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

    /// In-memory cache of API keys keyed by identifier
    private var cachedAPIKeys: [String: String] = [:]
    private var activeIdentifier: String = "apiKey"

    // MARK: – Generic Save/Read/Delete

    func save(_ data: Data, for account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String:   data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            DiagnosticLogger.shared.append("Keychain: Successfully saved item for account '\(account)'")
        } else {
            DiagnosticLogger.shared.appendError("Keychain save failed for account '\(account)' with status: \(status)")
        }
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
        if status == errSecSuccess {
            DiagnosticLogger.shared.append("Keychain: Retrieved data for account '\(account)'")
            if let data = dataTypeRef as? Data {
                return data
            } else {
                DiagnosticLogger.shared.appendWarning("Keychain: Retrieved item for account '\(account)' but data was nil or wrong type")
                return nil
            }
        } else if status == errSecItemNotFound {
            DiagnosticLogger.shared.appendWarning("Keychain read: no item found for account '\(account)'")
        } else {
            DiagnosticLogger.shared.appendError("Keychain read failed for account '\(account)' with status: \(status)")
        }
        return nil
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess {
            DiagnosticLogger.shared.append("Keychain: Deleted item for account '\(account)'")
        } else if status == errSecItemNotFound {
            DiagnosticLogger.shared.appendWarning("Keychain delete: no item to delete for account '\(account)'")
        } else {
            DiagnosticLogger.shared.appendError("Keychain delete failed for account '\(account)' with status: \(status)")
        }
    }

    // MARK: – API Key Convenience

    func setActiveIdentifier(_ identifier: String) {
        activeIdentifier = identifier
    }

    /// Save the API Key both to Keychain *and* to our in-memory cache.
    func saveAPIKey(_ apiKey: String, identifier: String? = nil) {
        let account = identifier ?? activeIdentifier
        cachedAPIKeys[account] = apiKey
        DiagnosticLogger.shared.append("Saving API Key for \(account): \(DiagnosticLogger.shared.maskAPIKey(apiKey))")

        if let data = apiKey.data(using: .utf8) {
            save(data, for: account)
        } else {
            DiagnosticLogger.shared.appendError("Failed to encode API key to Data")
        }
    }

    /// Return the API Key, reading from cache if available;
    /// otherwise, pull once from the Keychain and cache it.
    func getAPIKey(identifier: String? = nil) -> String? {
        let account = identifier ?? activeIdentifier
        if let key = cachedAPIKeys[account] {
            return key
        }

        if let data = read(account: account),
           let key = String(data: data, encoding: .utf8) {
            cachedAPIKeys[account] = key
            DiagnosticLogger.shared.append("Retrieved API Key from Keychain (\(account)): \(DiagnosticLogger.shared.maskAPIKey(key))")
            return key
        } else {
            DiagnosticLogger.shared.appendWarning("No API Key found in Keychain for account '\(account)'")
        }
        return nil
    }

    /// Wipe both the in-memory cache *and* the Keychain entry.
    func deleteAPIKey(identifier: String? = nil) {
        let account = identifier ?? activeIdentifier
        cachedAPIKeys.removeValue(forKey: account)
        DiagnosticLogger.shared.append("Cleared cached API key for account '\(account)'")
        delete(account: account)
    }

    func deleteAllAPIKeys() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            DiagnosticLogger.shared.append("Keychain: Cleared all stored API keys")
        } else {
            DiagnosticLogger.shared.appendError("Keychain bulk delete failed with status: \(status)")
        }
        cachedAPIKeys.removeAll()
        activeIdentifier = "apiKey"
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

    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var strippedScheme: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("https://") {
            return String(trimmed.dropFirst("https://".count))
        }
        if lower.hasPrefix("http://") {
            return String(trimmed.dropFirst("http://".count))
        }
        return trimmed
    }

    var isDemoEntry: Bool {
        strippedScheme.lowercased() == "demo"
    }
}

private let lastSeenISOFormatterWithFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let lastSeenISOFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

private let lastSeenDisplayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm dd/MM/yyyy"
    formatter.locale = Locale.current
    formatter.timeZone = TimeZone.current
    return formatter
}()

private func formatLastSeenTimestamp(_ dateString: String?) -> String {
    guard let value = dateString?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return "N/A"
    }
    if let parsed = lastSeenISOFormatterWithFractional.date(from: value) ?? lastSeenISOFormatter.date(from: value) {
        return lastSeenDisplayFormatter.string(from: parsed)
    }
    return value
}

// MARK: - Design Helpers

struct DarkGradientBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.07, blue: 0.12),
                Color(red: 0.02, green: 0.03, blue: 0.07)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .overlay(
            AngularGradient(
                colors: [
                    Color(red: 0.35, green: 0.55, blue: 0.90).opacity(0.18),
                    Color.clear,
                    Color(red: 0.35, green: 0.55, blue: 0.90).opacity(0.12),
                    Color.clear
                ],
                center: .center
            )
            .blur(radius: 160)
        )
    }
}

struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.55), radius: 24, x: 0, y: 18)
            )
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String?
    let systemImage: String

    init(_ title: String, subtitle: String? = nil, systemImage: String) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.cyan)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                }
            }
            Spacer()
        }
    }
}

private struct DonationSheet: View {
    /// Update these identifiers to match the in-app purchase product IDs configured in App Store Connect.
    private static let productIdentifiers = [
        "Donate1usd",
        "Donate5usd",
        "Donate10usd",
        "Donate20usd",
        "Donate50usd",
        "Donate100usd"
    ]

    @Environment(\.dismiss) private var dismiss
    @State private var products: [Product] = []
    @State private var isLoading = false
    @State private var statusMessage: String?
    @State private var isPurchasing = false

    var body: some View {
        NavigationStack {
            ZStack {
                DarkGradientBackground()
                VStack(spacing: 20) {
                    Text("Support Development")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.white)
                    Text("Select a donation amount to support ongoing work on TacticalRMM Manager.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.white.opacity(0.7))
                        .padding(.horizontal)

                    if isLoading {
                        ProgressView("Loading donation options…")
                            .tint(.cyan)
                    } else if products.isEmpty {
                        Text("Donation options are currently unavailable. Check back soon.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.white.opacity(0.7))
                            .padding(.horizontal)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            ForEach(products, id: \.id) { product in
                                Button {
                                    Task { await purchase(product) }
                                } label: {
                                    VStack(spacing: 4) {
                                        Text(product.displayPrice)
                                            .font(.headline)
                                        Text(product.displayName)
                                            .font(.caption)
                                            .foregroundStyle(Color.white.opacity(0.7))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 18)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.cyan)
                                .disabled(isPurchasing)
                            }
                        }
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.white)
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)
                    }
                }
                .padding(24)
            }
            .navigationTitle("Donate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            if products.isEmpty {
                await loadProducts()
            }
        }
    }

    @MainActor
    private func loadProducts() async {
        isLoading = true
        statusMessage = nil
        defer { isLoading = false }
        do {
            var fetched = try await Product.products(for: Self.productIdentifiers)
            fetched.sort { $0.price < $1.price }
            products = fetched
            let identifiers = fetched.map { $0.id.description }.joined(separator: ", ")
            DiagnosticLogger.shared.append("Loaded StoreKit products: \(identifiers)")
        } catch {
            statusMessage = "Unable to load donation options: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func purchase(_ product: Product) async {
        guard !isPurchasing else { return }
        isPurchasing = true
        statusMessage = nil
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    statusMessage = "Thank you for your support!"
                case .unverified(_, let error):
                    statusMessage = "Purchase unverified: \(error.localizedDescription)"
                }
            case .userCancelled:
                statusMessage = "Purchase cancelled."
            case .pending:
                statusMessage = "Purchase pending approval."
            @unknown default:
                statusMessage = "Purchase completed with an unknown result."
            }
        } catch {
            statusMessage = "Purchase failed: \(error.localizedDescription)"
        }
    }
}

struct ModernInputField: View {
    enum FieldKind { case text, secure }

    let title: String
    let placeholder: String
    @Binding var text: String
    var kind: FieldKind = .text
    var keyboard: UIKeyboardType = .default
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.6))
                .kerning(1.2)
            Group {
                switch kind {
                case .text:
                    if let focus {
                        TextField(placeholder, text: $text)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .keyboardType(keyboard)
                            .focused(focus)
                    } else {
                        TextField(placeholder, text: $text)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .keyboardType(keyboard)
                    }
                case .secure:
                    if let focus {
                        SecureField(placeholder, text: $text)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .focused(focus)
                    } else {
                        SecureField(placeholder, text: $text)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }
}

extension View {
    func primaryButton() -> some View {
        self.buttonStyle(.borderedProminent)
            .tint(Color.cyan)
            .controlSize(.large)
    }

    func secondaryButton() -> some View {
        self.buttonStyle(.bordered)
            .tint(Color.cyan.opacity(0.7))
            .controlSize(.large)
    }
}

// MARK: - Models

@Model
final class RMMSettings {
    var uuid: UUID = UUID()
    var displayName: String = "Default"
    var baseURL: String
    var keychainKey: String = ""

    init(displayName: String, baseURL: String) {
        let generated = UUID()
        self.uuid = generated
        self.displayName = displayName
        self.baseURL = baseURL
        self.keychainKey = "apiKey_\(generated.uuidString)"
    }

    init(baseURL: String) {
        let generated = UUID()
        self.uuid = generated
        self.displayName = "Default"
        self.baseURL = baseURL
        self.keychainKey = "apiKey_\(generated.uuidString)"
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
    let boot_time: TimeInterval?

    private enum CodingKeys: String, CodingKey {
        case agent_id, hostname, description, public_ip, local_ips, graphics, make_model, status, site_name, last_seen, physical_disks, custom_fields, serial_number, boot_time
        case operating_system
        case cpu_model
        // Alternate keys sometimes seen in APIs
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
         custom_fields: [CustomField]?,
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
        // Required minimal fields
        self.agent_id = try c.decode(String.self, forKey: .agent_id)
        self.hostname  = try c.decode(String.self, forKey: .hostname)

        // operating_system may be missing or under a different key
        if let os = try c.decodeIfPresent(String.self, forKey: .operating_system) {
            self.operating_system = os
        } else if let osAlt = try c.decodeIfPresent(String.self, forKey: .os) {
            self.operating_system = osAlt
        } else if let plat = try c.decodeIfPresent(String.self, forKey: .plat) {
            self.operating_system = plat
        } else {
            self.operating_system = "Unknown OS"
        }

        // cpu_model may be an array, string, or missing in list payload
        if let cpuArr = try c.decodeIfPresent([String].self, forKey: .cpu_model) {
            self.cpu_model = cpuArr
        } else if let cpuStr = try c.decodeIfPresent(String.self, forKey: .cpu_model) {
            self.cpu_model = cpuStr.isEmpty ? [] : [cpuStr]
        } else {
            self.cpu_model = []
        }

        self.description   = try c.decodeIfPresent(String.self, forKey: .description)
        self.public_ip     = try c.decodeIfPresent(String.self, forKey: .public_ip)
        self.local_ips     = try c.decodeIfPresent(String.self, forKey: .local_ips)
        self.graphics      = try c.decodeIfPresent(String.self, forKey: .graphics)
        self.make_model    = try c.decodeIfPresent(String.self, forKey: .make_model)
        self.status        = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        self.site_name     = try c.decodeIfPresent(String.self, forKey: .site_name)
        self.last_seen     = try c.decodeIfPresent(String.self, forKey: .last_seen)
        self.physical_disks = try c.decodeIfPresent([String].self, forKey: .physical_disks)
        self.custom_fields = try c.decodeIfPresent([CustomField].self, forKey: .custom_fields)
        self.serial_number = try c.decodeIfPresent(String.self, forKey: .serial_number)
        self.boot_time     = try c.decodeIfPresent(TimeInterval.self, forKey: .boot_time)
    }
}

struct AgentListResponse: Decodable {
    let count: Int?
    let next: String?
    let previous: String?
    let results: [Agent]
}

struct AgentRow: View {
    let agent: Agent
    let hideSensitiveInfo: Bool

    private var statusColor: Color {
        if agent.isOnlineStatus { return Color.green }
        if agent.isOfflineStatus { return Color.red }
        return Color.orange
    }

    private var statusLabel: String {
        agent.status.isEmpty ? "Unknown" : agent.status.capitalized
    }

    private var publicIPText: String {
        hideSensitiveInfo ? "••••••" : (agent.public_ip ?? "No IP available")
    }

    private var lanIPText: String {
        guard !hideSensitiveInfo else { return "••••••" }
        return agent.local_ips?.ipv4Only().isEmpty == false ? agent.local_ips!.ipv4Only() : "No LAN IP available"
    }

    private var lastSeenDisplay: String {
        formatLastSeenTimestamp(agent.last_seen)
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
                    Text("CPU: \(agent.cpu_model.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.7))
                }

                Text("Site: \(hideSensitiveInfo ? "••••••" : (agent.site_name ?? "Not available"))")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.7))

                Text("LAN: \(lanIPText)")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.7))

                Text("Public: \(publicIPText)")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.7))
            }

            if let lastSeen = agent.last_seen, !lastSeen.isEmpty {
                Text("Last Seen: \(lastSeenDisplay)")
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

private extension Agent {
    var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var isOnlineStatus: Bool {
        normalizedStatus == "online"
    }

    var isOfflineStatus: Bool {
        ["offline", "overdue", "dormant"].contains(normalizedStatus)
    }
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

// MARK: - Check Models

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

// MARK: - Agent Sorting

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
}

private extension AgentSortOption {
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

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var settingsList: [RMMSettings]

    @AppStorage("hideInstall") private var hideInstall: Bool = false
    @AppStorage("hideSensitive") private var hideSensitiveInfo: Bool = false
    @AppStorage("useFaceID") private var useFaceID: Bool = false
    @AppStorage("activeSettingsUUID") private var activeSettingsUUID: String = ""

    @State private var showGuideAlert = false
    @State private var showDiagnosticAlert = false
    @State private var showLogShareSheet = false
    @State private var showSettings = false
    @State private var showRecoveryAlert = false

    @State private var isAuthenticating = false
    @State private var didAuthenticate = false

    @State private var agents: [Agent] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var appliedSearchText = ""

    @State private var baseURLText: String = "https://"
    @State private var apiKeyText: String = ""

    @State private var sortOption: AgentSortOption = .none

    @FocusState private var searchFieldIsFocused: Bool
    @State private var transactionUpdatesTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            DarkGradientBackground()

            NavigationStack {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        heroCard
                        connectionCard
                        agentsCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 28)
                }
                .scrollDismissesKeyboard(.interactively)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.title3.weight(.semibold))
                        }
                        .foregroundStyle(Color.cyan)
                        .disabled(useFaceID && !didAuthenticate)
                    }
                }
            }
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
            .onAppear {
                DiagnosticLogger.shared.append("ContentView onAppear")
                if !useFaceID {
                    loadInitialSettings()
                }
                startTransactionUpdatesIfNeeded()
            }
            .onChange(of: activeSettingsUUID) { _, _ in
                applyActiveSettings()
            }
            .onChange(of: settingsList.map { $0.uuid }) { _, _ in
                if settingsList.isEmpty {
                    activeSettingsUUID = ""
                } else if !settingsList.contains(where: { $0.uuid.uuidString == activeSettingsUUID }) {
                    activeSettingsUUID = settingsList.first?.uuid.uuidString ?? ""
                }
                applyActiveSettings()
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("reloadAgents"))) { notification in
                guard !(useFaceID && !didAuthenticate) else { return }
                applyActiveSettings()
                if let settings = notification.object as? RMMSettings {
                    Task { await fetchAgents(using: settings) }
                } else if let settings = activeSettings {
                    Task { await fetchAgents(using: settings) }
                }
            }
            .onDisappear {
                transactionUpdatesTask?.cancel()
                transactionUpdatesTask = nil
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .background, .inactive:
                    didAuthenticate = false

                case .active:
                    guard useFaceID, !didAuthenticate else { return }

                    if !authAvailable {
                        showRecoveryAlert = true
                        return
                    }

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
            .onChange(of: useFaceID) { _, newValue in
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

            if useFaceID && !didAuthenticate {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()

                    Color.black.opacity(0.4)
                        .ignoresSafeArea()

                    ProgressView(isAuthenticating ? "Authenticating with FaceID…" : "Please wait…")
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                }
                .onAppear {
                    if !authAvailable {
                        showRecoveryAlert = true
                    }
                }
                .alert(isPresented: $showRecoveryAlert) {
                    Alert(
                        title: Text("Security Reset Required"),
                        message: Text("You've disabled both Face ID and device passcode while having the FaceID app lock enabled.\nFor security, you must clear all saved settings and API keys.\nTap \"Clear App Data\" to reset."),
                        dismissButton: .destructive(
                            Text("Clear App Data"),
                            action: clearAppData
                        )
                    )
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { showSettings && !(useFaceID && !didAuthenticate) },
            set: { showSettings = $0 }
        )) {
            SettingsView()
        }
        .sheet(isPresented: $showLogShareSheet) {
            if let url = DiagnosticLogger.shared.getLogFileURL() {
                ActivityView(activityItems: [url])
            } else {
                Text("No diagnostics log available.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("clearAppData"))) { _ in
            clearAppData()
        }
    }

    private var heroCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tactical RMM")
                        .font(.title2.weight(.semibold))
                    Text("Agent Manager")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 1.6, maximumDistance: 80) { pressing in
                    DiagnosticLogger.shared.append("Hero long press state: \(pressing)")
                } perform: {
                    DiagnosticLogger.shared.append("Hero long-press triggered diagnostics prompt")
                    showDiagnosticAlert = true
                }

                Text("Press and hold the title to export diagnostics or share logs with support.")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.5))

                if !agents.isEmpty {
                    let onlineCount = agents.filter { $0.isOnlineStatus }.count
                    let offlineCount = agents.filter { $0.isOfflineStatus }.count

                    Divider()
                        .overlay(Color.white.opacity(0.08))

                    ResponsiveBadgeRow(badges: [
                        .init(title: "Agents", value: String(agents.count), symbol: "desktopcomputer"),
                        .init(title: "Online", value: String(onlineCount), symbol: "bolt.horizontal.circle"),
                        .init(title: "Overdue", value: String(offlineCount), symbol: "moon.zzz")
                    ])
                }
            }
        }
    }

    private var connectionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader("Connection", subtitle: "Securely connect to Tactical RMM", systemImage: "lock.shield")

                if settingsList.isEmpty {
                    Text("No instances are configured. Open Settings to add your first server.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.7))

                    Button {
                        showSettings = true
                    } label: {
                        Label("Open Settings", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .primaryButton()
                } else if let saved = activeSettings {
                    let key = currentAPIKey()
                    connectionSummary(for: saved)

                    if let key, !key.isEmpty {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                refreshButton(for: saved)
                                if !hideInstall {
                                    installButton
                                }
                            }

                            VStack(spacing: 12) {
                                refreshButton(for: saved)
                                if !hideInstall {
                                    installButton
                                }
                            }
                        }
                    } else {
                        Text("API key missing for this instance. Update the credentials in Settings before refreshing.")
                            .font(.footnote)
                            .foregroundStyle(Color.red)

                        Button {
                            showSettings = true
                        } label: {
                            Label("Update Credentials", systemImage: "key.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .primaryButton()
                    }
                } else {
                    Text("Unable to determine the active instance. Open Settings to select a server.")
                        .font(.footnote)
                        .foregroundStyle(Color.red)

                    Button {
                        showSettings = true
                    } label: {
                        Label("Manage Instances", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .primaryButton()
                }

                if !settingsList.isEmpty {
                    Text("Note: Large environments may take longer to load on mobile hardware.")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
        }
    }

    @ViewBuilder
    private func refreshButton(for settings: RMMSettings) -> some View {
        let buttonTitle = agents.isEmpty ? "Fetch Agents" : "Refresh Agents"
        Button {
            DiagnosticLogger.shared.append("Login tapped.")
            Task { await fetchAgents(using: settings) }
        } label: {
            Label(buttonTitle, systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
        }
        .primaryButton()
    }

    private var installButton: some View {
        NavigationLink {
            InstallAgentView(
                baseURL: baseURLText,
                apiKey: apiKeyText
            )
        } label: {
            Label("Install Agent", systemImage: "square.and.arrow.down")
                .frame(maxWidth: .infinity)
        }
        .primaryButton()
    }

    @ViewBuilder
    private func connectionSummary(for settings: RMMSettings) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            summaryRow(title: "Instance", value: settings.displayName, systemImage: "server.rack")
            Text("Manage connection details, including URL and credentials, from Settings.")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.65))
        }
    }

    @ViewBuilder
    private func summaryRow(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.cyan)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.6))
                Text(value)
                    .font(.callout)
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
        }
    }

    private var agentsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(
                    "Agents",
                    subtitle: agents.isEmpty ? "Connect to retrieve your estate" : agentCountText,
                    systemImage: "list.bullet.rectangle"
                )

                if !agents.isEmpty || isLoading {
                    HStack {
                        Text(agentCountText)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.7))
                        Spacer()
                        Menu {
                            Picker("Sort agents", selection: $sortOption) {
                                ForEach(AgentSortOption.allCases) { option in
                                    Text(option.title).tag(option)
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.arrow.down")
                                Text(sortOption.chipLabel)
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                    )
                            )
                        }
                        .foregroundStyle(Color.cyan)
                        .menuStyle(.automatic)

                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showSearch.toggle()
                                if showSearch {
                                    searchFieldIsFocused = true
                                } else {
                                    searchText = ""
                                    appliedSearchText = ""
                                    searchFieldIsFocused = false
                                }
                            }
                        } label: {
                            Image(systemName: showSearch ? "magnifyingglass.circle.fill" : "magnifyingglass")
                                .font(.title3)
                        }
                        .foregroundStyle(Color.cyan)
                    }
                }

                if showSearch {
                    HStack {
                        TextField("Search hostname, OS, or description", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            )
                            .focused($searchFieldIsFocused)
                            .onChange(of: searchText) { _, newValue in
                                appliedSearchText = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            }

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showSearch = false
                                searchText = ""
                                appliedSearchText = ""
                                searchFieldIsFocused = false
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                    }
                }

                if isLoading {
                    ProgressView("Loading agents…")
                        .progressViewStyle(.circular)
                        .tint(Color.cyan)
                } else if let error = errorMessage {
                    Text("Error: \(error)")
                        .foregroundStyle(Color.red)
                        .font(.footnote)
                } else if filteredAgents.isEmpty {
                    Text(agents.isEmpty ? "No agents loaded. Save your connection to begin." : "No agents match your search.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(sortedAgentsForDisplay) { agent in
                            NavigationLink {
                                AgentDetailView(
                                    agent: agent,
                                    baseURL: baseURLText,
                                    apiKey: apiKeyText
                                )
                            } label: {
                                AgentRow(agent: agent, hideSensitiveInfo: hideSensitiveInfo)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private struct BadgeInfo: Identifiable {
        let id = UUID()
        let title: String
        let value: String
        let symbol: String
    }

    private struct ResponsiveBadgeRow: View {
        let badges: [BadgeInfo]

        var body: some View {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    ForEach(badges) { badge in
                        badgeView(for: badge)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(badges) { badge in
                        badgeView(for: badge)
                    }
                }
            }
        }

        @ViewBuilder
        private func badgeView(for badge: BadgeInfo) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: badge.symbol)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.cyan)
                    Text(badge.title.uppercased())
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(badge.value)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }

    private var agentCountText: String {
        let total = agents.count
        guard total > 0 else { return "No agents yet" }
        let displayed = sortedAgentsForDisplay.count
        if displayed == total && appliedSearchText.isEmpty && sortOption == .none {
            return "\(total) \(total == 1 ? "Agent" : "Agents")"
        }
        return "\(displayed) of \(total) agents"
    }

    private var filteredAgents: [Agent] {
        let base = agents.filter { sortOption.matches($0) }
        guard !appliedSearchText.isEmpty else { return base }
        let query = appliedSearchText.lowercased()
        return base.filter {
            $0.hostname.lowercased().contains(query) ||
            $0.operating_system.lowercased().contains(query) ||
            ($0.description?.lowercased().contains(query) ?? false)
        }
    }

    private var sortedAgentsForDisplay: [Agent] {
        switch sortOption {
        case .none:
            return filteredAgents.sorted {
                $0.hostname.localizedCaseInsensitiveCompare($1.hostname) == .orderedAscending
            }
        case .online:
            return filteredAgents.sorted { lhs, rhs in
                if lhs.isOnlineStatus == rhs.isOnlineStatus {
                    return lhs.hostname.localizedCaseInsensitiveCompare(rhs.hostname) == .orderedAscending
                }
                return lhs.isOnlineStatus && !rhs.isOnlineStatus
            }
        default:
            return filteredAgents.sorted { lhs, rhs in
                let left = sortOption.sortKey(for: lhs)
                let right = sortOption.sortKey(for: rhs)
                if left == right {
                    return lhs.hostname.localizedCaseInsensitiveCompare(rhs.hostname) == .orderedAscending
                }
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
        }
    }

    private var activeSettings: RMMSettings? {
        if let match = settingsList.first(where: { $0.uuid.uuidString == activeSettingsUUID }) {
            return ensureIdentifiers(for: match)
        }
        if let first = settingsList.first {
            return ensureIdentifiers(for: first)
        }
        return nil
    }

    // MARK: – Helper Methods

    private func enforceHTTPSPrefix(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "https://" }
        var sanitized = trimmed
        let lower = sanitized.lowercased()
        if lower.hasPrefix("https://") {
            sanitized = String(sanitized.dropFirst("https://".count))
        } else if lower.hasPrefix("http://") {
            sanitized = String(sanitized.dropFirst("http://".count))
        }
        return "https://" + sanitized
    }

    @MainActor
    private func applyActiveSettings() {
        guard let settings = activeSettings else {
            baseURLText = "https://"
            apiKeyText = ""
            KeychainHelper.shared.setActiveIdentifier("apiKey")
            return
        }

        let resolved = ensureIdentifiers(for: settings)
        KeychainHelper.shared.setActiveIdentifier(resolved.keychainKey)

        if resolved.baseURL.isDemoEntry {
            baseURLText = resolved.baseURL
        } else {
            baseURLText = enforceHTTPSPrefix(resolved.baseURL)
        }

        if let key = KeychainHelper.shared.getAPIKey(identifier: resolved.keychainKey) {
            apiKeyText = key
        } else {
            apiKeyText = ""
        }
    }

    @MainActor
    private func currentAPIKey() -> String? {
        guard let settings = activeSettings else { return nil }
        let resolved = ensureIdentifiers(for: settings)
        KeychainHelper.shared.setActiveIdentifier(resolved.keychainKey)
        if let stored = KeychainHelper.shared.getAPIKey(identifier: resolved.keychainKey), !stored.isEmpty {
            return stored
        }
        return apiKeyText.nonEmpty
    }

    @discardableResult
    @MainActor
    private func ensureIdentifiers(for settings: RMMSettings) -> RMMSettings {
        if settings.keychainKey.isEmpty {
            settings.keychainKey = "apiKey_\(settings.uuid.uuidString)"
        }
        if settings.displayName.isEmpty {
            settings.displayName = settings.baseURL
        }
        return settings
    }

    private func loadInitialSettings() {
        if activeSettingsUUID.isEmpty, let first = settingsList.first {
            activeSettingsUUID = first.uuid.uuidString
        }
        applyActiveSettings()
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            showGuideAlert = true
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        }
    }

    private func startTransactionUpdatesIfNeeded() {
        guard transactionUpdatesTask == nil else { return }
        transactionUpdatesTask = Task(priority: .background) {
            for await result in Transaction.updates {
                if Task.isCancelled { break }
                switch result {
                case .verified(let transaction):
                    await transaction.finish()
                    DiagnosticLogger.shared.append("Finished pending transaction: \(transaction.id)")
                case .unverified(let transaction, let error):
                    DiagnosticLogger.shared.appendError("Unverified transaction (\(transaction.id)): \(error.localizedDescription)")
                }
            }
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
        // 1) Remove API keys from both Keychain and cache
        KeychainHelper.shared.deleteAllAPIKeys()

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
        UserDefaults.standard.removeObject(forKey: "hideSensitive")

        // 4) Verify everything is gone
        let userDefaultsCleared =
            UserDefaults.standard.object(forKey: "hasLaunchedBefore") == nil &&
            UserDefaults.standard.object(forKey: "hideInstall") == nil &&
            UserDefaults.standard.object(forKey: "hideSensitive") == nil

        let coreDataCleared = settingsList.isEmpty && coreDataError == nil

        // 5) Only if all three areas are clean, disable FaceID lock
        if coreDataCleared && userDefaultsCleared {
            useFaceID = false
        } else {
            if !coreDataCleared {
                DiagnosticLogger.shared.appendWarning("SwiftData settings still exist after deletion.")
            }
            if !userDefaultsCleared {
                DiagnosticLogger.shared.appendWarning("AppStorage flags not fully cleared.")
            }
        }
        
        // 6) Remove the diagnostics log file
            if let logURL = DiagnosticLogger.shared.getLogFileURL() {
                do {
                    try FileManager.default.removeItem(at: logURL)
                    DiagnosticLogger.shared.append("Deleted diagnostics log file.")
                } catch {
                    print("Failed to delete log file: \(error)")
                }
            }

        // 7) Clear UI state and force a fresh launch
        baseURLText = "https://"
        apiKeyText = ""
        activeSettingsUUID = ""

        // 8) Terminate the app
        exit(0)
    }

    @MainActor
    private func fetchAgents(using settings: RMMSettings, retryCount: Int = 0) async {
        let attempt = retryCount + 1
        DiagnosticLogger.shared.append("fetchAgents started (attempt \(attempt))")
        let resolved = ensureIdentifiers(for: settings)
        KeychainHelper.shared.setActiveIdentifier(resolved.keychainKey)
        if settings.baseURL.isDemoEntry {
            DiagnosticLogger.shared.append("Demo mode detected, loading sample agents instead of performing network call.")
            isLoading = false
            errorMessage = nil
            loadDemoAgents()
            return
        }
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
        request.timeoutInterval = 45
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
                    do {
                        let decoder = JSONDecoder()
                        if let page = try? decoder.decode(AgentListResponse.self, from: data) {
                            agents = page.results
                            let reportedCount = page.count.map { String($0) } ?? "unknown"
                            DiagnosticLogger.shared.append("Fetched agents via wrapper: \(agents.count) (reported count: \(reportedCount))")
                        } else {
                            agents = try decoder.decode([Agent].self, from: data)
                            DiagnosticLogger.shared.append("Fetched agents via legacy array: \(agents.count)")
                        }
                    } catch {
                        if let decErr = error as? DecodingError {
                            let message: String
                            switch decErr {
                            case .keyNotFound(let key, let ctx):
                                message = "Decoding keyNotFound: \(key.stringValue) at \(ctx.codingPath.map{ $0.stringValue }.joined(separator: "."))"
                            case .typeMismatch(let type, let ctx):
                                message = "Decoding typeMismatch: \(type) at \(ctx.codingPath.map{ $0.stringValue }.joined(separator: "."))"
                            case .valueNotFound(let type, let ctx):
                                message = "Decoding valueNotFound: \(type) at \(ctx.codingPath.map{ $0.stringValue }.joined(separator: "."))"
                            case .dataCorrupted(let ctx):
                                message = "Decoding dataCorrupted at \(ctx.codingPath.map{ $0.stringValue }.joined(separator: "."))"
                            @unknown default:
                                message = "Decoding unknown error"
                            }
                            DiagnosticLogger.shared.appendError(message)
                        }
                        throw error
                    }
                case 401:
                    errorMessage = "Invalid API Key."
                    DiagnosticLogger.shared.appendError("HTTP 401 during fetch.")
                default:
                    errorMessage = "HTTP \(http.statusCode)"
                    DiagnosticLogger.shared.appendError("HTTP \(http.statusCode) during fetch.")
                }
            }
        } catch {
            if let urlError = error as? URLError, urlError.code == .timedOut, retryCount < 1 {
                DiagnosticLogger.shared.appendWarning("fetchAgents timed out on attempt \(attempt), retrying once.")
                Task { @MainActor in
                    await fetchAgents(using: settings, retryCount: retryCount + 1)
                }
                return
            }
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Error fetching agents: \(error.localizedDescription)")
        }
        isLoading = false
    }

    private func loadDemoAgents() {
        DiagnosticLogger.shared.append("Loading demo agents.")
        let now = Date().timeIntervalSince1970
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
                serial_number: "Demo Serial 1",
                boot_time:     now - 3600
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
                serial_number: "Demo Serial2",
                boot_time: now - 86400
            )
        ]
    }
}


// MARK: - SettingsView

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsList: [RMMSettings]

    @AppStorage("hideInstall") var hideInstall: Bool = false
    @AppStorage("useFaceID") var useFaceID: Bool = false
    @AppStorage("hideSensitive") var hideSensitiveInfo: Bool = false
    @AppStorage("activeSettingsUUID") private var activeSettingsUUID: String = ""

    @State private var showResetConfirmation = false
    @State private var showAddInstanceSheet = false
    @State private var newInstanceName: String = ""
    @State private var newInstanceURL: String = ""
    @State private var newInstanceKey: String = ""
    @State private var addInstanceError: String?
    @FocusState private var addInstanceField: AddInstanceField?
    @State private var editingInstance: RMMSettings?
    @State private var editInstanceName: String = ""
    @State private var editInstanceURL: String = ""
    @State private var editInstanceKey: String = ""
    @State private var editInstanceError: String?
    @FocusState private var editInstanceField: EditInstanceField?
    @State private var showDonationSheet = false

    private enum AddInstanceField: Hashable { case name, url, key }
    private enum EditInstanceField: Hashable { case name, url, key }

    private var authAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    private var activeSettings: RMMSettings? {
        if let match = settingsList.first(where: { $0.uuid.uuidString == activeSettingsUUID }) {
            return ensureIdentifiers(for: match)
        }
        if let first = settingsList.first {
            return ensureIdentifiers(for: first)
        }
        return nil
    }

    private var instanceSubtitle: String {
        if settingsList.isEmpty { return "No active instance" }
        if let active = activeSettings { return "Active: \(active.displayName)" }
        return "Select an instance"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                DarkGradientBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        instancesCard
                        preferencesCard
                        resourcesCard
                        dangerCard
                        footer
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 28)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.cyan)
                }
            }
            .sheet(isPresented: $showAddInstanceSheet) {
                addInstanceSheet
            }
            .sheet(isPresented: Binding(
                get: { editingInstance != nil },
                set: { if !$0 { cancelEditInstance() } }
            )) {
                if let instance = editingInstance {
                    editInstanceSheet(for: instance)
                }
            }
            .sheet(isPresented: $showDonationSheet) {
                DonationSheet()
            }
            .alert("Delete All App Data?", isPresented: $showResetConfirmation) {
                Button("Delete", role: .destructive) {
                    NotificationCenter.default.post(name: .init("clearAppData"), object: nil)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete all saved settings, API keys, and diagnostics logs. This action cannot be undone.")
            }
        }
    }

    private var instancesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader("Instances", subtitle: instanceSubtitle, systemImage: "server.rack")

                if settingsList.isEmpty {
                    Text("No instances configured yet. Add one below to get started.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(settingsList) { settings in
                            instanceRow(for: settings)
                        }
                    }
                }

                Button {
                    newInstanceName = ""
                    newInstanceURL = ""
                    newInstanceKey = ""
                    addInstanceError = nil
                    showAddInstanceSheet = true
                } label: {
                    Label("Add Instance", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .primaryButton()
            }
        }
    }

    private var preferencesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader("Preferences", subtitle: "Applies to this device", systemImage: "gearshape")

                settingsToggle(title: "Hide Install Agent Button", isOn: $hideInstall)

                settingsToggle(title: "Hide Sensitive Information", isOn: $hideSensitiveInfo)

                Toggle(isOn: $useFaceID) {
                    Text("Face ID App Lock")
                        .font(.callout)
                        .foregroundStyle(Color.white)
                }
                .toggleStyle(SwitchToggleStyle(tint: Color.cyan))
                .disabled(!authAvailable)
                .opacity(authAvailable ? 1 : 0.4)

                if !authAvailable {
                    Text("Requires a device passcode or biometrics enabling.")
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }
        }
    }

    private var resourcesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Resources", subtitle: "Helpful references", systemImage: "book")

                Button {
                    if let url = URL(string: "https://github.com/Jerdal-F/TacticalRMM-Manager") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Project Guide", systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .secondaryButton()

                Button {
                    showDonationSheet = true
                } label: {
                    Label("Donation", systemImage: "heart.fill")
                        .frame(maxWidth: .infinity)
                }
                .secondaryButton()
            }
        }
    }

    private var dangerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Danger Zone", subtitle: "Irreversible actions", systemImage: "exclamationmark.triangle")

                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Delete App Data", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
    }

    private var footer: some View {
        Text("This app is an independent project and is not affiliated with Tactical RMM or AmidaWare.")
            .font(.footnote)
            .foregroundStyle(Color.white.opacity(0.55))
            .multilineTextAlignment(.center)
            .padding(.horizontal)
    }

    private func instanceRow(for settings: RMMSettings) -> some View {
        let resolved = ensureIdentifiers(for: settings)
        let isActive = resolved.uuid.uuidString == activeSettingsUUID

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(resolved.displayName)
                        .font(.headline)
                    if isActive {
                        Text("ACTIVE")
                            .font(.caption2.weight(.bold))
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.cyan.opacity(0.2))
                            )
                    }
                }
                Text(resolved.baseURL)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            Menu {
                if !isActive {
                    Button("Set Active") {
                        setActiveInstance(resolved, triggerReload: true)
                    }
                }

                Button("Edit", systemImage: "pencil") {
                    beginEditing(resolved)
                }

                if settingsList.count > 1 {
                    Button("Delete Instance", role: .destructive) {
                        deleteInstance(resolved)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Color.white.opacity(0.8))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(isActive ? 0.12 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isActive ? Color.cyan.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var addInstanceSheet: some View {
        NavigationStack {
            ZStack {
                DarkGradientBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        SectionHeader("New Instance", subtitle: "Enter connection details", systemImage: "server.rack")

                        inputField(title: "Display Name", placeholder: "Server Name", text: $newInstanceName)
                            .focused($addInstanceField, equals: .name)

                        inputField(title: "Base URL", placeholder: "https://api.example.com", text: $newInstanceURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .focused($addInstanceField, equals: .url)

                        inputField(title: "API Key", placeholder: "Paste API key", text: $newInstanceKey, isSecure: true)
                            .focused($addInstanceField, equals: .key)

                        if let addInstanceError {
                            Text(addInstanceError)
                                .font(.footnote)
                                .foregroundStyle(Color.red)
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle("Add Instance")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAddInstanceSheet = false }
                        .foregroundStyle(Color.cyan)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { createInstance() }
                        .foregroundStyle(Color.cyan)
                        .disabled(newInstanceName.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  newInstanceURL.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  newInstanceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                addInstanceField = .name
            }
        }
        .presentationDetents([.fraction(0.55), .large])
    }

    @ViewBuilder
    private func editInstanceSheet(for settings: RMMSettings) -> some View {
        NavigationStack {
            ZStack {
                DarkGradientBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        SectionHeader("Edit Instance", subtitle: settings.displayName, systemImage: "pencil" )

                        inputField(title: "Display Name", placeholder: settings.displayName, text: $editInstanceName)
                            .focused($editInstanceField, equals: .name)

                        inputField(title: "Base URL", placeholder: "https://api.example.com", text: $editInstanceURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .focused($editInstanceField, equals: .url)

                        inputField(title: "API Key", placeholder: "Paste API key", text: $editInstanceKey, isSecure: true)
                            .focused($editInstanceField, equals: .key)

                        if let editInstanceError {
                            Text(editInstanceError)
                                .font(.footnote)
                                .foregroundStyle(Color.red)
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle("Edit Instance")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelEditInstance() }
                        .foregroundStyle(Color.cyan)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveEditedInstance() }
                        .foregroundStyle(Color.cyan)
                        .disabled(editInstanceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  editInstanceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  editInstanceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                editInstanceField = .name
            }
        }
        .presentationDetents([.fraction(0.55), .large])
    }

    private func settingsToggle(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.callout)
                .foregroundStyle(Color.white)
        }
        .toggleStyle(SwitchToggleStyle(tint: Color.cyan))
    }

    private func inputField(title: String, placeholder: String, text: Binding<String>, isSecure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.6))
                .kerning(1.2)
            Group {
                if isSecure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                        .autocorrectionDisabled(true)
                }
            }
            .textInputAutocapitalization(.never)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }

    @discardableResult
    private func ensureIdentifiers(for settings: RMMSettings) -> RMMSettings {
        if settings.keychainKey.isEmpty {
            settings.keychainKey = "apiKey_\(settings.uuid.uuidString)"
        }
        if settings.displayName.isEmpty {
            settings.displayName = settings.baseURL
        }
        return settings
    }

    private func setActiveInstance(_ settings: RMMSettings, triggerReload: Bool = false) {
        let resolved = ensureIdentifiers(for: settings)
        activeSettingsUUID = resolved.uuid.uuidString
        KeychainHelper.shared.setActiveIdentifier(resolved.keychainKey)
        if triggerReload {
            NotificationCenter.default.post(name: .init("reloadAgents"), object: resolved)
        }
    }

    private func deleteInstance(_ settings: RMMSettings) {
        let resolved = ensureIdentifiers(for: settings)
        KeychainHelper.shared.deleteAPIKey(identifier: resolved.keychainKey)
        let remaining = settingsList.filter { $0.uuid != resolved.uuid }
        modelContext.delete(resolved)
        do {
            try modelContext.save()
            DiagnosticLogger.shared.append("Deleted settings instance \(resolved.displayName)")
        } catch {
            DiagnosticLogger.shared.appendError("Failed to delete instance: \(error.localizedDescription)")
        }

        if remaining.isEmpty {
            activeSettingsUUID = ""
        } else if resolved.uuid.uuidString == activeSettingsUUID {
            if let newActive = remaining.first {
                setActiveInstance(newActive, triggerReload: true)
            }
        }
    }

    private func createInstance() {
        let trimmedName = newInstanceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = newInstanceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = newInstanceKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            addInstanceError = "Provide a display name."
            addInstanceField = .name
            return
        }
        guard !trimmedURL.isEmpty else {
            addInstanceError = "Provide the base URL."
            addInstanceField = .url
            return
        }
        guard !trimmedKey.isEmpty else {
            addInstanceError = "Provide the API key."
            addInstanceField = .key
            return
        }

        let normalizedURL = normalizeBaseURL(trimmedURL)
        let newSettings = RMMSettings(displayName: trimmedName, baseURL: normalizedURL.removingTrailingSlash())
        modelContext.insert(newSettings)

        KeychainHelper.shared.saveAPIKey(trimmedKey, identifier: newSettings.keychainKey)
        activeSettingsUUID = newSettings.uuid.uuidString
        KeychainHelper.shared.setActiveIdentifier(newSettings.keychainKey)

        do {
            try modelContext.save()
            DiagnosticLogger.shared.append("Created new instance \(trimmedName)")
            showAddInstanceSheet = false
            NotificationCenter.default.post(name: .init("reloadAgents"), object: newSettings)
        } catch {
            addInstanceError = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func normalizeBaseURL(_ raw: String) -> String {
        let lower = raw.lowercased()
        if raw.isDemoEntry { return "demo" }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return raw
        }
        return "https://" + raw
    }

    private func beginEditing(_ settings: RMMSettings) {
        let resolved = ensureIdentifiers(for: settings)
        editingInstance = resolved
        editInstanceName = resolved.displayName
        editInstanceURL = resolved.baseURL
        editInstanceKey = KeychainHelper.shared.getAPIKey(identifier: resolved.keychainKey) ?? ""
        editInstanceError = nil
        DispatchQueue.main.async {
            editInstanceField = .name
        }
    }

    private func cancelEditInstance() {
        editingInstance = nil
        editInstanceName = ""
        editInstanceURL = ""
        editInstanceKey = ""
        editInstanceError = nil
        editInstanceField = nil
    }

    private func saveEditedInstance() {
        guard let instance = editingInstance else { return }

        let trimmedName = editInstanceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = editInstanceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = editInstanceKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            editInstanceError = "Provide a display name."
            editInstanceField = .name
            return
        }
        guard !trimmedURL.isEmpty else {
            editInstanceError = "Provide the base URL."
            editInstanceField = .url
            return
        }
        guard !trimmedKey.isEmpty else {
            editInstanceError = "Provide the API key."
            editInstanceField = .key
            return
        }

        let normalizedURL = normalizeBaseURL(trimmedURL).removingTrailingSlash()
        let resolved = ensureIdentifiers(for: instance)
        resolved.displayName = trimmedName
        resolved.baseURL = normalizedURL
        KeychainHelper.shared.saveAPIKey(trimmedKey, identifier: resolved.keychainKey)

        do {
            try modelContext.save()
            DiagnosticLogger.shared.append("Updated instance \(trimmedName)")
            if resolved.uuid.uuidString == activeSettingsUUID {
                activeSettingsUUID = resolved.uuid.uuidString
            }
            NotificationCenter.default.post(name: .init("reloadAgents"), object: resolved)
            cancelEditInstance()
        } catch {
            editInstanceError = "Failed to save: \(error.localizedDescription)"
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
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    destinationCard
                    settingsCard
                    downloadCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }

            if isLoadingClients {
                loadingOverlay(message: "Loading clients…")
            }

            if isGenerating {
                loadingOverlay(message: "Generating installer…")
            }
        }
        .navigationTitle("Install Windows Agent")
        .task { await fetchClients() }
        .sheet(isPresented: $showShareSheet) {
            if let url = installerURL {
                ActivityView(activityItems: [url])
            }
        }
        .onChange(of: selectedClientId) { _, newValue in
            if let id = newValue, let client = clients.first(where: { $0.id == id }) {
                sites = client.sites
                selectedSiteId = nil
            } else {
                sites = []
                selectedSiteId = nil
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
                    DiagnosticLogger.shared.append("Error in fetchClients: HTTP Error: \(resp.statusCode)")
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

    private var destinationCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader("Destination", subtitle: destinationSubtitle, systemImage: "building.2")

                if let errorMessage {
                    statusBanner(message: errorMessage, isError: true)
                }

                if clients.isEmpty && !isLoadingClients && errorMessage == nil {
                    Text("No clients available. Verify your permissions or refresh.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                }

                selectionMenu(title: "Client", value: selectedClientName, placeholder: "Select a client", disabled: clients.isEmpty) {
                    Button("Clear Selection", role: .destructive) {
                        selectedClientId = nil
                    }
                    ForEach(clients) { client in
                        Button(client.name) {
                            selectedClientId = client.id
                        }
                    }
                }

                selectionMenu(title: "Site", value: selectedSiteName, placeholder: "Select a site", disabled: sites.isEmpty) {
                    Button("Clear Selection", role: .destructive) {
                        selectedSiteId = nil
                    }
                    ForEach(sites) { site in
                        Button(site.name) {
                            selectedSiteId = site.id
                        }
                    }
                }
            }
        }
    }

    private var settingsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader("Installer Settings", subtitle: "Configure agent options", systemImage: "slider.horizontal.3")

                VStack(alignment: .leading, spacing: 14) {
                    Text("Agent Type")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                    Picker("Agent Type", selection: $agentType) {
                        Text("Server").tag("server")
                        Text("Workstation").tag("workstation")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: agentType) { _, newValue in
                        if newValue == "server" {
                            power = false
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Architecture")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                    Picker("Architecture", selection: $arch) {
                        Text("64 bit").tag("amd64")
                        Text("32 bit").tag("386")
                    }
                    .pickerStyle(.segmented)
                }

                VStack(spacing: 12) {
                    toggleRow(title: "Disable sleep/hibernate", isOn: $power, disabled: agentType == "server")
                    toggleRow(title: "Enable RDP", isOn: $rdp)
                    toggleRow(title: "Enable Ping", isOn: $ping)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Expires (hours)")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                    TextField("24", text: $expires)
                        .keyboardType(.numberPad)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Installer File Name")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                    TextField("trmm-installer.exe", text: $fileName)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        )
                }
            }
        }
    }

    private var downloadCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader("Generate Installer", subtitle: "Download and share the agent", systemImage: "square.and.arrow.down")

                if let installerURL {
                    Text("Installer ready: \(installerURL.lastPathComponent)")
                        .font(.footnote)
                        .foregroundStyle(Color.green)
                        .textSelection(.enabled)
                }

                if generateDisabled {
                    Text("Select a client and site to enable the download button.")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                }

                Button {
                    Task { await generateInstaller() }
                } label: {
                    Label("Download Installer", systemImage: "icloud.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .primaryButton()
                .disabled(generateDisabled)
                .opacity(generateDisabled ? 0.5 : 1)

                Text("Installer expires after the specified duration. Share directly from the completion prompt.")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        }
    }

    private var generateDisabled: Bool {
        isGenerating || selectedClientId == nil || selectedSiteId == nil
    }

    private var destinationSubtitle: String {
        if isLoadingClients { return "Loading…" }
        if let client = selectedClientName.nonEmpty, let site = selectedSiteName.nonEmpty {
            return "\(client) • \(site)"
        }
        return "Choose where to deploy"
    }

    private var selectedClientName: String {
        if let id = selectedClientId, let client = clients.first(where: { $0.id == id }) {
            return client.name
        }
        return ""
    }

    private var selectedSiteName: String {
        if let id = selectedSiteId, let site = sites.first(where: { $0.id == id }) {
            return site.name
        }
        return ""
    }

    private func selectionMenu<Content: View>(title: String, value: String, placeholder: String, disabled: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.55))
            Menu {
                content()
            } label: {
                HStack {
                    Text(value.nonEmpty ?? placeholder)
                        .font(.callout)
                        .foregroundStyle(value.nonEmpty == nil ? Color.white.opacity(0.55) : Color.white)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
            }
            .disabled(disabled)
        }
    }

    private func toggleRow(title: String, isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.callout)
                .foregroundStyle(Color.white)
        }
        .toggleStyle(SwitchToggleStyle(tint: Color.cyan))
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private func statusBanner(message: String, isError: Bool) -> some View {
        let tint: Color = isError ? .red : .green
        let icon = isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tint.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func loadingOverlay(message: String) -> some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            ProgressView(message)
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(12)
        }
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
    @State private var pendingPowerAction: PowerActionType?
    @AppStorage("hideSensitive") private var hideSensitiveInfo: Bool = false
    @State private var hasLoadedDetailsOnce: Bool = false
    
    var effectiveAPIKey: String {
        return KeychainHelper.shared.getAPIKey() ?? apiKey
    }
    
    private var isDemoMode: Bool {
         return baseURL.isDemoEntry &&
             effectiveAPIKey.lowercased() == "demo"
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
                        var cleaned = responseString.trimmingCharacters(in: .whitespacesAndNewlines)
                        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count >= 2 {
                            cleaned.removeFirst()
                            cleaned.removeLast()
                        }
                        message = cleaned.isEmpty ? "Wake‑on‑LAN sent successfully!" : cleaned
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
    /// Returns a human‐readable uptime like "2 days 3 hours 15 minutes"
    func formattedUptime(from bootInterval: TimeInterval?) -> String {
        guard let bootInterval else { return "N/A" }
        let bootDate = Date(timeIntervalSince1970: bootInterval)
        let totalSeconds = Int(Date().timeIntervalSince(bootDate))

        let minuteSeconds = 60
        let hourSeconds   = 60 * minuteSeconds
        let daySeconds    = 24 * hourSeconds
        let monthSeconds  = 31 * daySeconds  // define a “month” as 31 days

        let months  = totalSeconds / monthSeconds
        let days    = (totalSeconds % monthSeconds) / daySeconds
        let hours   = (totalSeconds % daySeconds) / hourSeconds
        let minutes = (totalSeconds % hourSeconds) / minuteSeconds

        var parts: [String] = []
        if months > 0 {
            parts.append("\(months) month" + (months == 1 ? "" : "s"))
        }
        if days > 0 {
            parts.append("\(days) day" + (days == 1 ? "" : "s"))
        }
        if hours > 0 {
            parts.append("\(hours) hour" + (hours == 1 ? "" : "s"))
        }
        // always show minutes if nothing else, or if non-zero
        if minutes > 0 || parts.isEmpty {
            parts.append("\(minutes) minute" + (minutes == 1 ? "" : "s"))
        }
        return parts.joined(separator: " ")
    }

    /// Non-empty custom fields to display in AgentDetailView
    private var nonEmptyCustomFields: [CustomField] {
        let fields = updatedAgent?.custom_fields ?? agent.custom_fields ?? []
        return fields.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private enum PowerActionType: String, Identifiable {
        case reboot
        case shutdown

        var id: String { rawValue }

        var title: String {
            switch self {
            case .reboot: return "Confirm Reboot"
            case .shutdown: return "Confirm Shutdown"
            }
        }

        var message: String {
            switch self {
            case .reboot: return "Are you sure you want to reboot this agent?"
            case .shutdown: return "Are you sure you want to shutdown this agent?"
            }
        }

        var confirmLabel: String {
            switch self {
            case .reboot: return "Reboot"
            case .shutdown: return "Shutdown"
            }
        }
    }

    private var currentAgent: Agent { updatedAgent ?? agent }

    private var descriptionText: String? {
        guard let text = currentAgent.description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private var serialDisplay: String {
        let serial = updatedAgent?.serial_number ?? agent.serial_number ?? ""
        if hideSensitiveInfo { return "••••••" }
        return serial.isEmpty ? "N/A" : serial
    }

    private var cpuDisplay: String {
        let models = currentAgent.cpu_model.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return models.isEmpty ? "N/A" : models.joined(separator: ", ")
    }

    private var gpuDisplay: String {
        currentAgent.graphics?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "No GPU available"
    }

    private var modelDisplay: String {
        currentAgent.make_model?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Not available"
    }

    private var disksDisplayText: String {
        let disks = currentAgent.physical_disks?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
        return disks.isEmpty ? "N/A" : disks.joined(separator: "\n")
    }

    private var siteDisplay: String {
        hideSensitiveInfo ? "••••••" : (currentAgent.site_name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Not available")
    }

    private var lanDisplay: String {
        guard !hideSensitiveInfo else { return "••••••" }
        if let lan = currentAgent.local_ips?.ipv4Only().trimmingCharacters(in: .whitespacesAndNewlines), !lan.isEmpty {
            return lan
        }
        return "No LAN IP available"
    }

    private var publicDisplay: String {
        guard !hideSensitiveInfo else { return "••••••" }
        return currentAgent.public_ip?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "No IP available"
    }

    private var statusLabel: String {
        currentAgent.status.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Unknown"
    }

    private var statusColor: Color {
        if currentAgent.isOnlineStatus { return Color.green }
        if currentAgent.isOfflineStatus { return Color.red }
        return Color.orange
    }

    private var lastSeenDisplay: String {
        formatLastSeenTimestamp(currentAgent.last_seen)
    }

    private var uptimeDisplay: String {
        formattedUptime(from: currentAgent.boot_time)
    }

    private var overviewCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(currentAgent.hostname)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                        Text(currentAgent.operating_system)
                            .font(.subheadline)
                            .foregroundStyle(Color.white.opacity(0.7))
                            .textSelection(.enabled)
                    }
                    Spacer()
                    statusPill
                }

                if let descriptionText {
                    Text(descriptionText)
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.7))
                        .textSelection(.enabled)
                }

                infoRow("Site", value: siteDisplay, systemImage: "building.2")
            }
        }
    }

    private var hardwareCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Hardware", subtitle: "Key system specs", systemImage: "cpu")
                infoRow("CPU", value: cpuDisplay, systemImage: "cpu")
                infoRow("GPU", value: gpuDisplay, systemImage: "display")
                infoRow("Model", value: modelDisplay, systemImage: "macmini.fill")
                infoRow("Serial", value: serialDisplay, systemImage: "barcode")
                infoRow("Physical Disks", value: disksDisplayText, systemImage: "internaldrive")
            }
        }
    }

    private var networkCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Network", subtitle: "Connectivity overview", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                infoRow("LAN IP", value: lanDisplay, systemImage: "network")
                infoRow("Public IP", value: publicDisplay, systemImage: "globe")
            }
        }
    }

    private var insightCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Insight", subtitle: "Recent activity", systemImage: "clock")
                infoRow("Status", value: statusLabel, systemImage: "dot.radiowaves.left.and.right", tint: statusColor)
                infoRow("Last Seen", value: lastSeenDisplay, systemImage: "clock.arrow.circlepath")
                infoRow("Uptime", value: uptimeDisplay, systemImage: "timer")
            }
        }
    }

    private var powerCard: some View {
        return GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Power Controls", subtitle: "Send remote power actions", systemImage: "bolt.fill")
                VStack(spacing: 16) {
                    HStack(spacing: 16) {
                        Button {
                            pendingPowerAction = .reboot
                        } label: {
                            AgentActionTile(
                                title: "Reboot",
                                subtitle: "Graceful restart",
                                systemImage: "arrow.clockwise.circle.fill",
                                tint: Color.orange
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)

                        Button {
                            pendingPowerAction = .shutdown
                        } label: {
                            AgentActionTile(
                                title: "Shutdown",
                                subtitle: "Power down agent",
                                systemImage: "power.circle.fill",
                                tint: Color.red
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }

                    Button {
                        Task { await performWakeOnLan() }
                    } label: {
                        AgentActionTile(
                            title: "Wake",
                            subtitle: "Wake-on-LAN",
                            systemImage: "dot.radiowaves.up.forward",
                            tint: Color.green
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }

                if let message, !message.isEmpty {
                    powerMessageView(message)
                }
            }
        }
    }

    private var managementCard: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Management", subtitle: "Inspect or interact", systemImage: "rectangle.connected.to.line.below")
                LazyVGrid(columns: columns, spacing: 16) {
                    NavigationLink {
                        AgentProcessesView(
                            agentId: agent.agent_id,
                            baseURL: baseURL,
                            apiKey: effectiveAPIKey
                        )
                    } label: {
                        AgentActionTile(
                            title: "Processes",
                            subtitle: "Running tasks",
                            systemImage: "chart.bar.doc.horizontal.fill",
                            tint: Color.cyan
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        SendCommandView(
                            agentId: agent.agent_id,
                            baseURL: baseURL,
                            apiKey: effectiveAPIKey
                        )
                    } label: {
                        AgentActionTile(
                            title: "Command",
                            subtitle: "Run scripts",
                            systemImage: "terminal.fill",
                            tint: Color.purple
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        AgentNotesView(
                            agentId: agent.agent_id,
                            baseURL: baseURL,
                            apiKey: effectiveAPIKey
                        )
                    } label: {
                        AgentActionTile(
                            title: "Notes",
                            subtitle: "Technician notes",
                            systemImage: "note.text",
                            tint: Color.blue
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        AgentTasksView(
                            agentId: agent.agent_id,
                            baseURL: baseURL,
                            apiKey: effectiveAPIKey
                        )
                    } label: {
                        AgentActionTile(
                            title: "Tasks",
                            subtitle: "Scheduled jobs",
                            systemImage: "checklist",
                            tint: Color.teal
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        AgentChecksView(
                            agentId: agent.agent_id,
                            baseURL: baseURL,
                            apiKey: effectiveAPIKey
                        )
                    } label: {
                        AgentActionTile(
                            title: "Checks",
                            subtitle: "Agent checks",
                            systemImage: "waveform.path.ecg",
                            tint: Color.orange
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        AgentCustomFieldsView(customFields: nonEmptyCustomFields)
                    } label: {
                        AgentActionTile(
                            title: "Custom Fields",
                            subtitle: "Metadata",
                            systemImage: "doc.text.fill",
                            tint: Color.indigo
                        )
                    }
                    .buttonStyle(.plain)
                    .opacity(nonEmptyCustomFields.isEmpty ? 0.45 : 1.0)
                    .allowsHitTesting(!nonEmptyCustomFields.isEmpty)

                }

                NavigationLink {
                    RunScriptView(
                        agent: agent,
                        baseURL: baseURL,
                        apiKey: effectiveAPIKey
                    )
                } label: {
                    AgentActionTile(
                        title: "Run Script",
                        subtitle: "Execute saved",
                        systemImage: "play.rectangle.on.rectangle.fill",
                        tint: Color.pink
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            Capsule(style: .continuous)
                .fill(statusColor.opacity(0.16))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(statusColor.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func infoRow(_ title: String, value: String, systemImage: String, tint: Color? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.cyan)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.55))
                Text(value)
                    .font(.body)
                    .foregroundStyle(tint ?? Color.white)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
    }

    private func powerMessageView(_ message: String) -> some View {
        let tint = messageColor(for: message)
        let icon = messageIcon(for: message)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tint.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func messageColor(for message: String) -> Color {
        let lower = message.lowercased()
        if lower.contains("success") || lower.contains("sent") || lower.contains("completed") {
            return .green
        }
        if lower.contains("error") || lower.contains("fail") || lower.contains("invalid") || lower.contains("http") {
            return .red
        }
        return .orange
    }

    private func messageIcon(for message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("success") || lower.contains("sent") || lower.contains("completed") {
            return "checkmark.circle.fill"
        }
        if lower.contains("error") || lower.contains("fail") || lower.contains("invalid") || lower.contains("http") {
            return "exclamationmark.triangle.fill"
        }
        return "info.circle.fill"
    }

    private struct AgentActionTile: View {
        let title: String
        let subtitle: String?
        let systemImage: String
        let tint: Color

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.white)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(tint.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(tint.opacity(0.35), lineWidth: 1)
                    )
            )
        }
    }
    
    var body: some View {
        ZStack {
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    overviewCard
                    hardwareCard
                    networkCard
                    insightCard
                    powerCard
                    managementCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }

            if isProcessing {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                ProgressView("Working…")
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .navigationTitle(currentAgent.hostname)
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $pendingPowerAction) { action in
            Alert(
                title: Text(action.title),
                message: Text(action.message),
                primaryButton: .destructive(Text(action.confirmLabel)) {
                    Task {
                        switch action {
                        case .reboot:
                            DiagnosticLogger.shared.append("Reboot command confirmed by user.")
                        case .shutdown:
                            DiagnosticLogger.shared.append("Shutdown command confirmed by user.")
                        }
                        await performAction(action: action.rawValue)
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .onAppear {
            DiagnosticLogger.shared.append("AgentDetailView onAppear")
            guard !hasLoadedDetailsOnce else { return }
            hasLoadedDetailsOnce = true
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
    @FocusState private var timeoutFocused: Bool
    @FocusState private var commandFocused: Bool
    @State private var processedCommandOutput: String = ""
    
    var effectiveAPIKey: String {
        return KeychainHelper.shared.getAPIKey() ?? apiKey
    }
    
    var body: some View {
        ZStack {
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    executionCard
                    commandCard
                    outputCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }

            if isProcessing {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                ProgressView("Sending Command…")
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .navigationTitle("Send Command")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var trimmedCommand: String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizeCommandOutput(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\r", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\"\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clearCommandOutput() {
        outputText = ""
        processedCommandOutput = ""
    }

    private func updateCommandOutput(with raw: String) {
        outputText = raw
        processedCommandOutput = sanitizeCommandOutput(raw)
    }
    
    private var executionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader("Execution", subtitle: "Configure remote command", systemImage: "terminal")
                Picker("Shell", selection: $selectedShell) {
                    Text("CMD").tag("cmd")
                    Text("PowerShell").tag("powershell")
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    Image(systemName: "timer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.cyan)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TIMEOUT (SECONDS)")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.55))
                        TextField("30", text: $timeout)
                            .keyboardType(.numberPad)
                            .focused($timeoutFocused)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            )
                    }
                }

                Toggle("Run as logged-in user", isOn: $runAsUser)
                    .toggleStyle(SwitchToggleStyle(tint: .cyan))

                Button {
                    UIApplication.shared.dismissKeyboard()
                    timeoutFocused = false
                    commandFocused = false
                    Task { await sendCommand() }
                } label: {
                    Label("Send Command", systemImage: "paperplane.fill")
                }
                .primaryButton()
                .disabled(trimmedCommand.isEmpty || isProcessing)

                if let statusMessage {
                    messageBanner(statusMessage)
                }
            }
        }
    }
    
    private var commandCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Command", subtitle: "Enter the script to run", systemImage: "chevron.left.forwardslash.chevron.right")
                TextEditor(text: $command)
                    .focused($commandFocused)
                    .frame(minHeight: 180)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    )
                    .font(.body.monospaced())
                    .foregroundStyle(Color.white)
            }
        }
    }
    
    private var outputCard: some View {
        CommandOutputCard(text: processedCommandOutput)
            .equatable()
    }

    private func messageBanner(_ message: String) -> some View {
        let tint = statusTint(for: message)
        let icon = statusIcon(for: message)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tint.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func statusTint(for message: String) -> Color {
        let lower = message.lowercased()
        if lower.contains("success") || lower.contains("sent") || lower.contains("completed") {
            return .green
        }
        if lower.contains("error") || lower.contains("fail") || lower.contains("invalid") || lower.contains("http") {
            return .red
        }
        return .orange
    }

    private func statusIcon(for message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("success") || lower.contains("sent") || lower.contains("completed") {
            return "checkmark.circle.fill"
        }
        if lower.contains("error") || lower.contains("fail") || lower.contains("invalid") || lower.contains("http") {
            return "exclamationmark.triangle.fill"
        }
        return "info.circle.fill"
    }

    // Wraps the command output to avoid costly re-layout when the text is unchanged.
    private struct CommandOutputCard: View, Equatable {
        let text: String

        static func == (lhs: CommandOutputCard, rhs: CommandOutputCard) -> Bool {
            lhs.text == rhs.text
        }

        var body: some View {
            GlassCard {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader("Output", subtitle: "Response from the agent", systemImage: "terminal")
                    if text.isEmpty {
                        Text("No output yet. Send a command to view the response here.")
                            .font(.footnote)
                            .foregroundStyle(Color.white.opacity(0.65))
                    } else {
                        ScrollView {
                            Text(text)
                                .font(.callout.monospaced())
                                .foregroundStyle(Color.white)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 180)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        )
                    }
                }
            }
        }
    }
    
    @MainActor
    func sendCommand() async {
        guard let timeoutInt = Int(timeout) else {
            statusMessage = "Invalid timeout value"
            return
        }

        let sanitizedCommand = trimmedCommand
        guard !sanitizedCommand.isEmpty else {
            statusMessage = "Enter a command before sending."
            return
        }

        command = sanitizedCommand
        isProcessing = true
        clearCommandOutput()
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
            "cmd": sanitizedCommand,
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

        DiagnosticLogger.shared.logHTTPRequest(
            method: "POST",
            url: url.absoluteString,
            headers: request.allHTTPHeaderFields ?? [:]
        )
        DiagnosticLogger.shared.append("Body: \(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(
                    method: "POST",
                    url: url.absoluteString,
                    status: httpResponse.statusCode,
                    data: data
                )

                if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 {
                    statusMessage = "Command sent successfully!"
                } else {
                    statusMessage = "HTTP Error: \(httpResponse.statusCode)"
                }

                if let decoded = try? JSONDecoder().decode(String.self, from: data) {
                    updateCommandOutput(with: decoded)
                } else {
                    var raw = String(data: data, encoding: .utf8) ?? ""
                    if raw.hasPrefix("\"") && raw.hasSuffix("\""), raw.count >= 2 {
                        raw.removeFirst()
                        raw.removeLast()
                    }
                    updateCommandOutput(with: raw)
                }
            }
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
            DiagnosticLogger.shared.appendError("Error sending command: \(error.localizedDescription)")
        }

        isProcessing = false
    }
}

// MARK: - RunScriptView

struct RunScriptView: View {
    let agent: Agent
    let baseURL: String
    let apiKey: String

    @State private var scripts: [RMMScript] = []
    @State private var isLoadingScripts = false
    @State private var scriptsError: String?
    @State private var selectedScriptID: Int?
    @State private var timeout: String = ""
    @State private var runAsUser: Bool = false
    @State private var deliverResultsViaEmail: Bool = false
    @State private var emailDeliveryMode: EmailDeliveryMode = .defaultRecipients
    @State private var customEmailInput: String = ""
    @State private var customScriptArguments: String = ""
    @State private var customEnvironmentVariables: String = ""
    @State private var statusMessage: String?
    @State private var outputMessage: String = ""
    @State private var isRunningScript = false
    @State private var hasLoadedScripts = false
    @State private var processedOutputText: String = ""
    @FocusState private var timeoutFocused: Bool
    @State private var showScriptPicker = false

    private static let demoScripts: [RMMScript] = [
        RMMScript(
            id: 147,
            name: "Check Uptime",
            description: "Queries the current uptime and reports the value.",
            scriptType: "userdefined",
            shell: "python",
            args: [],
            category: "TRMM (Win):Maintenance",
            favorite: false,
            defaultTimeout: 90,
            syntax: nil,
            filename: nil,
            hidden: false,
            supportedPlatforms: ["windows"],
            runAsUser: true,
            envVars: []
        ),
        RMMScript(
            id: 136,
            name: "Windows Update Install",
            description: "Installs pending Windows Updates.",
            scriptType: "userdefined",
            shell: "powershell",
            args: [],
            category: "TRMM (Win):Maintenance",
            favorite: false,
            defaultTimeout: 900,
            syntax: nil,
            filename: nil,
            hidden: false,
            supportedPlatforms: ["windows"],
            runAsUser: false,
            envVars: []
        ),
        RMMScript(
            id: 137,
            name: "Clean Temp Files",
            description: "Removes temporary files from common Windows locations.",
            scriptType: "userdefined",
            shell: "python",
            args: [],
            category: "TRMM (Win):Maintenance",
            favorite: false,
            defaultTimeout: 200,
            syntax: nil,
            filename: nil,
            hidden: false,
            supportedPlatforms: ["windows"],
            runAsUser: true,
            envVars: []
        )
    ]

    var body: some View {
        ZStack {
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    selectionCard
                    configurationCard
                    resultCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }

            if isLoadingScripts || isRunningScript {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                ProgressView(isLoadingScripts ? "Loading scripts…" : "Running script…")
                    .tint(Color.cyan)
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .navigationTitle("Run Script")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadScriptsIfNeeded() }
        .onChange(of: selectedScriptID) { _, newValue in
            guard let id = newValue, let script = scripts.first(where: { $0.id == id }) else { return }
            applyDefaults(for: script)
        }
        .onChange(of: scripts.map { $0.id }) { _, _ in
            let newScripts = scripts
            guard let current = selectedScriptID,
                  newScripts.contains(where: { $0.id == current }) else {
                selectedScriptID = nil
                timeout = ""
                runAsUser = false
                deliverResultsViaEmail = false
                emailDeliveryMode = .defaultRecipients
                customEmailInput = ""
                customScriptArguments = ""
                customEnvironmentVariables = ""
                statusMessage = nil
                clearScriptOutput()
                return
            }
        }
        .onChange(of: timeout) { _, newValue in
            let stripped = newValue.filter { $0.isNumber }
            if stripped != newValue {
                timeout = stripped
            }
        }
        .sheet(isPresented: $showScriptPicker) {
            ScriptPickerView(
                scripts: scripts,
                agentPlatform: normalizedAgentPlatform,
                selectedScriptID: $selectedScriptID
            )
            .presentationDetents([.medium, .large])
        }
    }

    private enum EmailDeliveryMode: String, CaseIterable, Identifiable {
        case defaultRecipients = "default"
        case custom = "custom"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .defaultRecipients: return "Account default"
            case .custom: return "Custom list"
            }
        }
    }

    private var selectionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader("Scripts", subtitle: "Choose a saved automation", systemImage: "scroll")

                if isLoadingScripts {
                    ProgressView("Loading scripts…")
                        .tint(Color.cyan)
                } else if let error = scriptsError {
                    Text("Error: \(error)")
                        .font(.footnote)
                        .foregroundStyle(Color.red)
                } else if scripts.isEmpty {
                    Text("No scripts available. Create scripts in Tactical RMM first.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else {
                    Button {
                        showScriptPicker = true
                    } label: {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(selectedScript?.name ?? "Choose a script")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.white)
                                if let script = selectedScript {
                                    Text(scriptCategory(for: script))
                                        .font(.caption)
                                        .foregroundStyle(Color.white.opacity(0.65))
                                } else if hasCompatibleScript {
                                    Text("Browse available scripts")
                                        .font(.caption)
                                        .foregroundStyle(Color.white.opacity(0.65))
                                } else {
                                    Text("No compatible scripts available")
                                        .font(.caption)
                                        .foregroundStyle(Color.red.opacity(0.85))
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(Color.cyan)
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)

                    if let script = selectedScript {
                        scriptSummary(for: script)
                    } else {
                        Text(hasCompatibleScript ? "Pick a script to view its details and defaults." : "No scripts are compatible with this agent's platform.")
                            .font(.caption)
                            .foregroundStyle(hasCompatibleScript ? Color.white.opacity(0.6) : Color.red.opacity(0.85))
                    }
                }
            }
        }
    }

    private var configurationCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader("Configuration", subtitle: "Adjust runtime options", systemImage: "slider.horizontal.3")

                if let script = selectedScript {
                    if let description = script.description?.nonEmpty {
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(Color.white.opacity(0.7))
                            .textSelection(.enabled)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        scriptMetaRow(systemImage: "square.stack.3d.up", label: "Category", value: script.category?.nonEmpty ?? "Uncategorized")
                        scriptMetaRow(systemImage: "terminal", label: "Shell", value: script.shell.uppercased())
                        scriptMetaRow(systemImage: "clock", label: "Default Timeout", value: "\(script.defaultTimeout) seconds")
                        scriptMetaRow(systemImage: "desktopcomputer", label: "Platforms", value: platformsLabel(for: script))
                    }

                    if !script.args.isEmpty {
                        defaultScriptSection(title: "Arguments", content: script.args.joined(separator: "\n"))
                    }

                    if !script.envVars.isEmpty {
                        defaultScriptSection(
                            title: "Environment Variables",
                            content: script.envVars.map { variable in
                                if let value = variable.value?.nonEmpty {
                                    return "\(variable.name)=\(value)"
                                }
                                return variable.name
                            }.joined(separator: "\n")
                        )
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Runtime Options")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.55))
                            .textCase(.uppercase)

                        HStack(spacing: 12) {
                            Image(systemName: "timer")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.cyan)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Timeout (seconds)")
                                    .font(.caption2)
                                    .foregroundStyle(Color.white.opacity(0.55))
                                TextField(String(script.defaultTimeout), text: $timeout)
                                    .keyboardType(.numberPad)
                                    .focused($timeoutFocused)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(Color.white.opacity(0.05))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                            )
                                    )
                            }
                        }

                        argumentEditor
                        environmentEditor

                        Toggle("Run as logged-in user", isOn: $runAsUser)
                            .toggleStyle(SwitchToggleStyle(tint: .cyan))

                        Toggle("Email results", isOn: $deliverResultsViaEmail)
                            .toggleStyle(SwitchToggleStyle(tint: .cyan))

                        if deliverResultsViaEmail {
                            Picker("Delivery method", selection: $emailDeliveryMode) {
                                ForEach(EmailDeliveryMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            if emailDeliveryMode == .custom {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Recipients")
                                        .font(.caption2)
                                        .foregroundStyle(Color.white.opacity(0.55))
                                        .textCase(.uppercase)
                                    TextField("user@example.com, second@example.com", text: $customEmailInput)
                                        .keyboardType(.emailAddress)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled(true)
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 12)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(Color.white.opacity(0.05))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                                )
                                        )
                                    Text("Separate multiple addresses with commas or spaces.")
                                        .font(.caption2)
                                        .foregroundStyle(Color.white.opacity(0.45))
                                }
                            }
                        }
                    }

                    Button {
                        UIApplication.shared.dismissKeyboard()
                        timeoutFocused = false
                        Task { await runSelectedScript() }
                    } label: {
                        Label("Run Script", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .primaryButton()
                    .disabled(isRunningScript || selectedScript == nil)

                    if let statusMessage {
                        messageBanner(statusMessage)
                    }
                } else {
                    Text("Pick a script to configure runtime options.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                }
            }
        }
    }

    private var resultCard: some View {
        ScriptResultCard(text: processedOutputText)
            .equatable()
    }

    private var selectedScript: RMMScript? {
        guard let id = selectedScriptID else { return nil }
        return scripts.first(where: { $0.id == id })
    }

    private var hasCompatibleScript: Bool {
        let platform = normalizedAgentPlatform
        if platform.isEmpty { return !scripts.isEmpty }
        return scripts.contains { scriptSupports($0, platform: platform) }
    }

    private var effectiveAPIKey: String {
        KeychainHelper.shared.getAPIKey() ?? apiKey
    }

    private var isDemoMode: Bool {
        baseURL.isDemoEntry && effectiveAPIKey.lowercased() == "demo"
    }

    private func clearScriptOutput() {
        outputMessage = ""
        processedOutputText = ""
    }

    private func updateScriptOutput(with raw: String) {
        outputMessage = raw
        processedOutputText = normalizeScriptOutputString(raw)
    }

    private var normalizedAgentPlatform: String {
        Self.normalizedPlatformIdentifier(from: agent.operating_system) ?? ""
    }

    private func platformsLabel(for script: RMMScript) -> String {
        let platforms = script.supportedPlatforms
        if platforms.isEmpty { return "All platforms" }
        return platforms.joined(separator: ", ")
    }

    private func scriptCategory(for script: RMMScript) -> String {
        script.category?.nonEmpty ?? "Uncategorized"
    }

    private func scriptSummary(for script: RMMScript) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.cyan)
                Text(script.category?.nonEmpty ?? "Uncategorized")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            Text("Shell: \(script.shell.uppercased()) • Timeout: \(script.defaultTimeout)s")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.55))
            Text("Platforms: \(platformsLabel(for: script))")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.55))
        }
    }

    private func scriptMetaRow(systemImage: String, label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.cyan)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.55))
                Text(value)
                    .font(.callout)
                    .foregroundStyle(Color.white)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    private var argumentEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Script Arguments")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.55))
                .textCase(.uppercase)
            ScriptTextEditor(text: $customScriptArguments, placeholder: "Enter arguments separated by spaces")
        }
    }

    private var environmentEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Environment Variables")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.55))
                .textCase(.uppercase)
            ScriptTextEditor(text: $customEnvironmentVariables, placeholder: "KEY=value, one per line")
        }
    }

    private func defaultScriptSection(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.55))
                .textCase(.uppercase)
            Text(content)
                .font(.callout.monospaced())
                .foregroundStyle(Color.white)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
        }
    }

    private struct ScriptTextEditor: View {
        @Binding var text: String
        let placeholder: String

        var body: some View {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.callout.monospaced())
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    )

                if text.isEmpty {
                    Text(placeholder)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.4))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    // Prevents the result panel from re-rendering while the user edits unrelated fields.
    private struct ScriptResultCard: View, Equatable {
        let text: String

        static func == (lhs: ScriptResultCard, rhs: ScriptResultCard) -> Bool {
            lhs.text == rhs.text
        }

        var body: some View {
            GlassCard {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader("Result", subtitle: "Output from the agent", systemImage: "doc.text")
                    if text.isEmpty {
                        Text("Run a script to view the response here.")
                            .font(.footnote)
                            .foregroundStyle(Color.white.opacity(0.65))
                    } else {
                        ScrollView {
                            Text(text)
                                .font(.callout.monospaced())
                                .foregroundStyle(Color.white)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 160)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        )
                    }
                }
            }
        }
    }

    private struct RunScriptPayload: Encodable {
        struct EnvVar: Encodable {
            let name: String
            let value: String?
        }

        let output: String
        let emails: [String]
        let emailMode: String
        let customField: String?
        let saveAllOutput: Bool
        let script: Int
        let args: [String]
        let envVars: [EnvVar]
        let timeout: Int
        let runAsUser: Bool
        let runOnServer: Bool = false

        enum CodingKeys: String, CodingKey {
            case output, emails, emailMode
            case customField = "custom_field"
            case saveAllOutput = "save_all_output"
            case script, args
            case envVars = "env_vars"
            case timeout
            case runAsUser = "run_as_user"
            case runOnServer = "run_on_server"
        }
    }

    private func messageBanner(_ message: String) -> some View {
        let tint = statusTint(for: message)
        let icon = statusIcon(for: message)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tint.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func statusTint(for message: String) -> Color {
        let lower = message.lowercased()
        if lower.contains("success") || lower.contains("queued") || lower.contains("sent") {
            return .green
        }
        if lower.contains("error") || lower.contains("fail") || lower.contains("invalid") || lower.contains("http") {
            return .red
        }
        return .orange
    }

    private func statusIcon(for message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("success") || lower.contains("queued") || lower.contains("sent") {
            return "checkmark.circle.fill"
        }
        if lower.contains("error") || lower.contains("fail") || lower.contains("invalid") || lower.contains("http") {
            return "exclamationmark.triangle.fill"
        }
        return "info.circle.fill"
    }

    @MainActor
    private func loadScriptsIfNeeded() async {
        guard !hasLoadedScripts else { return }
        hasLoadedScripts = true
        await loadScripts()
    }

    @MainActor
    private func loadScripts() async {
        isLoadingScripts = true
        scriptsError = nil
        defer { isLoadingScripts = false }

        if isDemoMode {
            scripts = RunScriptView.demoScripts
            selectedScriptID = nil
            timeout = ""
            runAsUser = false
            deliverResultsViaEmail = false
            emailDeliveryMode = .defaultRecipients
            customEmailInput = ""
            customScriptArguments = ""
            customEnvironmentVariables = ""
            statusMessage = nil
            clearScriptOutput()
            return
        }

        let sanitized = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitized)/scripts/?showCommunityScripts=false") else {
            scriptsError = "Invalid URL."
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        request.addDefaultHeaders(apiKey: effectiveAPIKey)
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

                guard http.statusCode == 200 else {
                    scriptsError = "HTTP \(http.statusCode)"
                    return
                }
            }

            let decoder = JSONDecoder()
            let decoded = try decoder.decode([RMMScript].self, from: data)
            scripts = decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            selectedScriptID = nil
            timeout = ""
            runAsUser = false
            deliverResultsViaEmail = false
            emailDeliveryMode = .defaultRecipients
            customEmailInput = ""
            customScriptArguments = ""
            customEnvironmentVariables = ""
            statusMessage = nil
            clearScriptOutput()
        } catch {
            scriptsError = error.localizedDescription
            DiagnosticLogger.shared.appendError("Error loading scripts: \(error.localizedDescription)")
        }
    }

    private static func normalizedPlatformIdentifier(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower == "all" || lower == "any" { return nil }
        if lower.contains("mac") || lower.contains("darwin") || lower.contains("osx") { return "darwin" }
        if lower.contains("lin") || lower.contains("nix") { return "linux" }
        if lower.contains("win") { return "windows" }
        return lower
    }

    private static func scriptSupports(_ script: RMMScript, platform: String) -> Bool {
        guard let normalizedPlatform = normalizedPlatformIdentifier(from: platform) else { return true }
        let normalizedScriptPlatforms = script.supportedPlatforms.compactMap { normalizedPlatformIdentifier(from: $0) }
        if normalizedScriptPlatforms.isEmpty { return true }
        return normalizedScriptPlatforms.contains(normalizedPlatform)
    }

    private func scriptSupports(_ script: RMMScript, platform: String) -> Bool {
        Self.scriptSupports(script, platform: platform)
    }

    private func applyDefaults(for script: RMMScript) {
        let platform = normalizedAgentPlatform
        guard scriptSupports(script, platform: platform) else {
            statusMessage = "This script is not compatible with the selected agent."
            selectedScriptID = nil
            return
        }
        timeout = String(max(script.defaultTimeout, 1))
        runAsUser = script.runAsUser
        deliverResultsViaEmail = false
        emailDeliveryMode = .defaultRecipients
        customEmailInput = ""
        customScriptArguments = script.args.joined(separator: " ")
        customEnvironmentVariables = script.envVars
            .map { variable in
                if let value = variable.value?.nonEmpty {
                    return "\(variable.name)=\(value)"
                }
                return variable.name
            }
            .joined(separator: "\n")
        statusMessage = nil
        clearScriptOutput()
    }

    @MainActor
    private func runSelectedScript() async {
        guard let script = selectedScript else {
            statusMessage = "Select a script before running."
            return
        }

        guard scriptSupports(script, platform: normalizedAgentPlatform) else {
            statusMessage = "This script is not compatible with the selected agent."
            return
        }

        let trimmedTimeout = timeout.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeoutSeconds: Int
        if trimmedTimeout.isEmpty {
            timeoutSeconds = max(script.defaultTimeout, 1)
            timeout = String(timeoutSeconds)
        } else if let value = Int(trimmedTimeout), value > 0 {
            timeoutSeconds = value
        } else {
            statusMessage = "Enter a timeout greater than zero."
            return
        }

        let argumentList = parsedArguments(from: customScriptArguments)
        let environmentEntries: [RunScriptPayload.EnvVar]
        do {
            environmentEntries = try parsedEnvironmentVariables(from: customEnvironmentVariables)
        } catch {
            statusMessage = error.localizedDescription
            return
        }

        let outputSetting: String
        let emailModeValue: String
        let emailList: [String]

        if deliverResultsViaEmail {
            outputSetting = "email"
            switch emailDeliveryMode {
            case .defaultRecipients:
                emailModeValue = "default"
                emailList = []
            case .custom:
                let parsedEmails = parsedCustomEmails()
                if parsedEmails.isEmpty {
                    statusMessage = "Add at least one email address or switch to account default delivery."
                    return
                }
                if let invalid = invalidEmails(in: parsedEmails).first {
                    statusMessage = "Invalid email: \(invalid)"
                    return
                }
                emailModeValue = "custom"
                emailList = parsedEmails
            }
        } else {
            outputSetting = "wait"
            emailModeValue = "default"
            emailList = []
        }

        isRunningScript = true
        statusMessage = nil
        clearScriptOutput()

        if isDemoMode {
            statusMessage = deliverResultsViaEmail ? "Demo mode: email delivery simulated." : "Demo mode: script queued successfully."
            updateScriptOutput(with: "Simulated execution of \(script.name) with timeout \(timeoutSeconds)s.")
            isRunningScript = false
            return
        }

        let sanitized = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitized)/agents/\(agent.agent_id)/runscript/") else {
            statusMessage = "Invalid URL."
            isRunningScript = false
            return
        }

        let payload = RunScriptPayload(
            output: outputSetting,
            emails: emailList,
            emailMode: emailModeValue,
            customField: nil,
            saveAllOutput: false,
            script: script.id,
            args: argumentList,
            envVars: environmentEntries,
            timeout: timeoutSeconds,
            runAsUser: runAsUser
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Match the request timeout to the user-selected script timeout.
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        request.addDefaultHeaders(apiKey: effectiveAPIKey)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()

        do {
            request.httpBody = try encoder.encode(payload)
        } catch {
            statusMessage = "Failed to encode request: \(error.localizedDescription)"
            isRunningScript = false
            return
        }

        DiagnosticLogger.shared.logHTTPRequest(
            method: "POST",
            url: url.absoluteString,
            headers: request.allHTTPHeaderFields ?? [:]
        )
        if let bodyString = String(data: request.httpBody ?? Data(), encoding: .utf8) {
            DiagnosticLogger.shared.append("RunScript payload: \(bodyString)")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(
                    method: "POST",
                    url: url.absoluteString,
                    status: http.statusCode,
                    data: data
                )
                if (200...299).contains(http.statusCode) {
                    statusMessage = "Script queued successfully."
                } else {
                    statusMessage = "HTTP \(http.statusCode)"
                }
            }

            if !data.isEmpty {
                if let result = try? JSONDecoder().decode(ScriptResults.self, from: data) {
                    updateScriptOutput(with: formatScriptResult(result))
                } else if let decodedString = try? JSONDecoder().decode(String.self, from: data) {
                    updateScriptOutput(with: decodedString)
                } else if let raw = String(data: data, encoding: .utf8), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    updateScriptOutput(with: raw)
                }
            }
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
            DiagnosticLogger.shared.appendError("RunScript error: \(error.localizedDescription)")
        }

        isRunningScript = false
    }

    private func formatScriptResult(_ result: ScriptResults) -> String {
        var segments: [String] = []
        if let name = result.scriptName?.nonEmpty {
            segments.append("Script: \(name)")
        }
        if let stdout = result.stdout?.nonEmpty {
            segments.append("Output:\n\(stdout)")
        }
        if let stderr = result.stderr?.nonEmpty {
            segments.append("Errors:\n\(stderr)")
        }
        if let retcode = result.retcode {
            segments.append("Return Code: \(retcode)")
        }
        if let execution = result.executionTime {
            segments.append("Execution Time: \(String(format: "%.2f", execution))s")
        }
        return segments.joined(separator: "\n\n")
    }

    private func normalizeScriptOutputString(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count >= 2 {
            cleaned.removeFirst()
            cleaned.removeLast()
        }
        cleaned = cleaned.replacingOccurrences(of: "\\r\\n", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\\n", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\\r", with: "")
        cleaned = cleaned.replacingOccurrences(of: "\\t", with: "\t")
        cleaned = cleaned.replacingOccurrences(of: "\\\"", with: "\"")
        cleaned = cleaned.replacingOccurrences(of: "\\\\", with: "\\")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parsedArguments(from text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
    }

    private func parsedEnvironmentVariables(from text: String) throws -> [RunScriptPayload.EnvVar] {
        let lines = text.components(separatedBy: CharacterSet.newlines)
        var envVars: [RunScriptPayload.EnvVar] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let components = trimmed.split(separator: "=", maxSplits: 1)
            guard components.count == 2 else {
                throw ValidationError("Invalid environment variable format: \(trimmed)")
            }
            let key = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw ValidationError("Environment variable name cannot be empty.")
            }
            envVars.append(RunScriptPayload.EnvVar(name: key, value: value.isEmpty ? nil : value))
        }
        return envVars
    }

    private struct ValidationError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func parsedCustomEmails() -> [String] {
        let separators = CharacterSet(charactersIn: ",; \n\t")
        return customEmailInput
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func invalidEmails(in emails: [String]) -> [String] {
        emails.filter { !isPlausibleEmail($0) }
    }

    private func isPlausibleEmail(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains(" ") else { return false }
        let parts = value.split(separator: "@")
        guard parts.count == 2, parts[0].count > 0, parts[1].contains(".") else { return false }
        return true
    }

    private struct ScriptPickerView: View {
        let scripts: [RMMScript]
        let agentPlatform: String
        @Binding var selectedScriptID: Int?

        @Environment(\.dismiss) private var dismiss
        @State private var searchText: String = ""

        private var filteredScripts: [RMMScript] {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return scripts }
            let lower = trimmed.lowercased()
            return scripts.filter { script in
                script.name.lowercased().contains(lower) ||
                (script.description?.lowercased().contains(lower) ?? false) ||
                (script.category?.lowercased().contains(lower) ?? false)
            }
        }

        private var groupedScripts: [(category: String, items: [RMMScript])] {
            let grouping = Dictionary(grouping: filteredScripts) { script -> String in
                script.category?.nonEmpty ?? "Uncategorized"
            }
            let sortedKeys = grouping.keys.sorted { lhs, rhs in
                lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
            return sortedKeys.map { key in
                let scripts = grouping[key]?.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } ?? []
                return (key, scripts)
            }
        }

        private func supports(_ script: RMMScript) -> Bool {
            RunScriptView.scriptSupports(script, platform: agentPlatform)
        }

        var body: some View {
            NavigationStack {
                Group {
                    if scripts.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "tray")
                                .font(.largeTitle)
                                .foregroundStyle(Color.cyan)
                            Text("No scripts available")
                                .font(.headline)
                                .foregroundStyle(Color.white)
                            Text("Create or import scripts in Tactical RMM to select them here.")
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(Color.white.opacity(0.65))
                                .padding(.horizontal)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DarkGradientBackground().ignoresSafeArea())
                    } else {
                        List {
                            ForEach(groupedScripts, id: \.category) { group in
                                Section(header: Text(group.category)) {
                                    ForEach(group.items) { script in
                                        ScriptSelectionButton(
                                            script: script,
                                            isSelected: selectedScriptID == script.id,
                                            isSupported: supports(script)
                                        ) {
                                            selectedScriptID = script.id
                                            dismiss()
                                        }
                                    }
                                }
                            }
                        }
                        .scrollContentBackground(.hidden)
                        .listStyle(.insetGrouped)
                        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search scripts")
                        .background(DarkGradientBackground().ignoresSafeArea())
                        .overlay {
                            if filteredScripts.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.title2)
                                        .foregroundStyle(Color.cyan)
                                    Text("No scripts match your search.")
                                        .font(.footnote)
                                        .foregroundStyle(Color.white.opacity(0.7))
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Select Script")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }

        private struct ScriptRow: View {
            let script: RMMScript
            let isSelected: Bool
            let supported: Bool

            private var categoryLabel: String {
                script.category?.nonEmpty ?? "Uncategorized"
            }

            private var compatibilityLabel: String? {
                supported ? nil : "Incompatible"
            }

            var body: some View {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(script.name)
                                .font(.headline)
                                .foregroundStyle(Color.white)
                            if script.favorite {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.yellow)
                            }
                        }
                        Text(categoryLabel)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.7))
                        Text("Shell: \(script.shell.uppercased()) • Timeout: \(script.defaultTimeout)s")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    Spacer(minLength: 0)
                    if let compatibilityLabel {
                        Text(compatibilityLabel)
                            .font(.caption2.weight(.semibold))
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.red.opacity(0.15))
                            )
                            .foregroundStyle(Color.red)
                    }
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.cyan)
                    }
                }
                .padding(.vertical, 6)
                .opacity(supported ? 1 : 0.6)
            }
        }

        private struct ScriptSelectionButton: View {
            let script: RMMScript
            let isSelected: Bool
            let isSupported: Bool
            let onSelect: () -> Void

            var body: some View {
                Button {
                    guard isSupported else { return }
                    onSelect()
                } label: {
                    ScriptRow(script: script, isSelected: isSelected, supported: isSupported)
                }
                .buttonStyle(.plain)
                .disabled(!isSupported)
            }
        }
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
    @State private var searchQuery: String = ""
    @State private var appliedSearchQuery: String = ""

    @State private var selectedProcess: ProcessRecord? = nil
    @FocusState private var searchFocused: Bool
    @State private var killBannerMessage: String? = nil
    @State private var deletedPIDs: Set<Int> = []  // Keep recently killed PIDs hidden until reloaded
    @State private var processFetchSequence: Int = 0  // Prevent stale fetches from overwriting fresh data

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
        ZStack {
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    searchCard
                    processListCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 180)
            }
            .refreshable {
                await fetchProcesses(force: true)
            }

            if isLoading {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                ProgressView("Loading processes…")
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .navigationTitle("Agent Processes")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showKillSheet, onDismiss: { pidToKill = "" }) {
            killSheet
        }
        .overlay(alignment: .bottom) {
            stickyKillBar
        }
        .onAppear {
            Task { await fetchProcesses() }
        }
    }

    private var searchCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Process Search", subtitle: "Filter by name", systemImage: "magnifyingglass")
                TextField("Search process name", text: $searchQuery)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .focused($searchFocused)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    )
                    .onSubmit { appliedSearchQuery = searchQuery }
                    .onChange(of: searchQuery) { _, newValue in
                        if newValue.isEmpty { appliedSearchQuery = "" }
                    }

                if let errorMessage {
                    statusBanner(errorMessage, isError: true)
                }
            }
        }
    }

    private var processListCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Processes", subtitle: listSubtitle, systemImage: "memorychip")

                if processRecords.isEmpty && errorMessage == nil && !isLoading {
                    Text("No processes found.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else if displayedProcesses.isEmpty && !processRecords.isEmpty {
                    Text("No processes match your search.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(displayedProcesses) { process in
                            ProcessTile(
                                process: process,
                                isSelected: selectedProcess?.id == process.id
                            )
                            .onTapGesture {
                                if selectedProcess?.id == process.id {
                                    selectedProcess = nil
                                } else {
                                    selectedProcess = process
                                }
                            }
                            .opacity(deletedPIDs.contains(process.pid) ? 0.2 : 1)
                        }
                    }
                }

                if let killBannerMessage {
                    statusBanner(killBannerMessage, isError: killBannerMessage.lowercased().contains("fail") || killBannerMessage.lowercased().contains("error"))
                }
            }
        }
    }

    private var stickyKillBar: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader("Terminate Process", subtitle: "Select a process or enter PID", systemImage: "nosign")

            if let process = selectedProcess {
                Text("Ready to kill \(process.name) (PID \(process.pid)).")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.85))
            } else {
                Text("Tap a process above or enter a PID manually.")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.7))
            }

            Button {
                Task {
                    if let process = selectedProcess {
                        await killProcess(withPid: process.pid)
                    } else {
                        showKillSheet = true
                    }
                }
            } label: {
                Label(selectedProcessLabel, systemImage: "trash.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.black.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.55), radius: 24, x: 0, y: 18)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private var listSubtitle: String {
        if isLoading { return "Loading…" }
        if !appliedSearchQuery.isEmpty { return "Filtered: \(displayedProcesses.count)" }
        return "Total: \(processRecords.count)"
    }

    private var selectedProcessLabel: String {
        if let process = selectedProcess {
            return "Kill \(process.name) (PID \(process.pid))"
        }
        return "Kill Process by PID"
    }

    private var killSheet: some View {
        NavigationView {
            ZStack {
                DarkGradientBackground()
                VStack(spacing: 24) {
                    Text("Enter PID to terminate")
                        .font(.headline)
                        .foregroundStyle(Color.white)
                    TextField("PID", text: $pidToKill)
                        .keyboardType(.numberPad)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        )
                        .foregroundStyle(Color.white)

                    HStack(spacing: 16) {
                        Button("Cancel") {
                            showKillSheet = false
                        }
                        .secondaryButton()

                        Button("Confirm", role: .destructive) {
                            Task {
                                if let pidInt = Int(pidToKill), pidInt > 0 {
                                    await killProcess(withPid: pidInt)
                                } else {
                                    killBannerMessage = "Invalid PID"
                                }
                                showKillSheet = false
                            }
                        }
                        .primaryButton()
                        .tint(.red)
                    }
                }
                .padding(24)
            }
            .navigationBarHidden(true)
        }
        .presentationDetents([.fraction(0.35)])
    }

    private func statusBanner(_ message: String, isError: Bool) -> some View {
        let tint: Color = isError ? .red : .green
        let icon = isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            Text(message)
                .foregroundStyle(Color.white)
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tint.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private struct ProcessTile: View {
        let process: ProcessRecord
        let isSelected: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(process.name)
                        .font(.headline)
                    Spacer()
                    Text("PID \(process.pid)")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                Text("User: \(process.username)")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.7))
                HStack(spacing: 12) {
                    pill(label: "CPU \(process.cpu_percent)%", color: Color.orange)
                    pill(label: "RAM \(process.membytes)", color: Color.cyan)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.12 : 0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(isSelected ? Color.cyan.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }

        private func pill(label: String, color: Color) -> some View {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(color.opacity(0.18))
                )
        }
    }

    @MainActor
    func fetchProcesses(force: Bool = false) async {
        processFetchSequence &+= 1
        let fetchID = processFetchSequence
        if !force {
            guard !isLoading else { return }
            isLoading = true
            errorMessage = nil
        } else {
            errorMessage = nil
        }
        defer {
            if !force {
                isLoading = false
            }
        }
        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/\(agentId)/processes/") else {
            errorMessage = "Invalid URL"
            DiagnosticLogger.shared.appendError("Invalid URL in fetching processes.")
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
                    return
                }
            }
            let decodedProcesses = try JSONDecoder().decode([ProcessRecord].self, from: data)
            guard fetchID == processFetchSequence else {
                DiagnosticLogger.shared.append("Discarded stale process fetch (id: \(fetchID))")
                return
            }
            processRecords = decodedProcesses
            deletedPIDs.removeAll()
        } catch {
            guard fetchID == processFetchSequence else {
                DiagnosticLogger.shared.append("Discarded stale process fetch error (id: \(fetchID))")
                return
            }
            if error is CancellationError {
                DiagnosticLogger.shared.append("Process fetch cancelled")
                return
            }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                DiagnosticLogger.shared.append("Process fetch cancelled by URLSession")
                return
            }
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Error fetching processes: \(error.localizedDescription)")
        }
    }

    @MainActor
    func killProcess(withPid pid: Int) async {
        killBannerMessage = nil
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
                if (200...299).contains(httpResponse.statusCode) {
                    killBannerMessage = "Process \(pid) killed successfully!"
                    selectedProcess = nil
                    processRecords.removeAll { $0.pid == pid }
                    deletedPIDs.insert(pid)
                    pidToKill = ""
                } else {
                    killBannerMessage = "Failed to kill process \(pid)."
                    DiagnosticLogger.shared.appendError("Failed to kill process \(pid), HTTP status \(httpResponse.statusCode).")
                }
            }
        } catch {
            killBannerMessage = "Error: \(error.localizedDescription)"
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

    private static let noteISOFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let noteISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let noteFallbackParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private static let noteDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return formatter
    }()

    var effectiveAPIKey: String {
        return KeychainHelper.shared.getAPIKey() ?? apiKey
    }

    var body: some View {
        ZStack {
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    notesHeaderCard
                    notesListCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }

            if isLoading {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                ProgressView("Loading notes…")
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .navigationTitle("Agent Notes")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await fetchNotes() }
        }
    }

    private var notesHeaderCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Technician Notes", subtitle: headerSubtitle, systemImage: "note.text")
                if let errorMessage {
                    banner(message: errorMessage, isError: true)
                }
            }
        }
    }

    private var notesListCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                if notes.isEmpty && !isLoading && errorMessage == nil {
                    Text("No notes available for this agent.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(notes) { note in
                            NoteTile(note: note, formattedDate: formattedNoteDate(note.entry_time))
                        }
                    }
                }
            }
        }
    }

    private var headerSubtitle: String {
        if isLoading { return "Loading…" }
        return notes.count == 1 ? "1 note" : "\(notes.count) notes"
    }

    private func formattedNoteDate(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "N/A" }

        if let parsed = AgentNotesView.noteISOFormatterWithFractional.date(from: trimmed)
            ?? AgentNotesView.noteISOFormatter.date(from: trimmed)
            ?? AgentNotesView.noteFallbackParser.date(from: trimmed) {
            return AgentNotesView.noteDisplayFormatter.string(from: parsed)
        }

        return trimmed
    }

    private func banner(message: String, isError: Bool) -> some View {
        let tint: Color = isError ? .red : .green
        let icon = isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tint.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private struct NoteTile: View {
        let note: Note
        let formattedDate: String

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(note.note)
                    .font(.body)
                    .foregroundStyle(Color.white)
                    .textSelection(.enabled)
                Divider()
                    .overlay(Color.white.opacity(0.1))
                HStack(spacing: 16) {
                    detailPill(system: "person.fill", label: note.username)
                    detailPill(system: "calendar", label: formattedDate)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }

        private func detailPill(system: String, label: String) -> some View {
            HStack(spacing: 6) {
                Image(systemName: system)
                Text(label)
            }
            .font(.caption2)
            .foregroundStyle(Color.white.opacity(0.75))
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
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

    // ISO8601 parser for task dates
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    // ISO8601 parser without fractional seconds for dates lacking fractional part
    private let isoNoFractionFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    // Fallback parser for strings like "2025-06-21T15:05:05" (no timezone)
    private let noTZDateParser: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return df
    }()
    // Formatter for display dates
    private let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm dd/MM/yyyy"
        return formatter
    }()

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
        ZStack {
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    tasksHeaderCard
                    tasksListCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }

            if isLoading {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                ProgressView("Loading tasks…")
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .navigationTitle("Agent Tasks")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await fetchTasks() }
        }
    }

    private var tasksHeaderCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Scheduled Tasks", subtitle: headerSubtitle, systemImage: "checklist")
                if let errorMessage {
                    banner(message: errorMessage, isError: true)
                }
            }
        }
    }

    private var tasksListCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                if tasks.isEmpty && !isLoading && errorMessage == nil {
                    Text("No tasks found for this agent.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(tasks) { task in
                            TaskTile(task: task, formattedRunTime: formattedDate(task.run_time_date), formattedCreated: formattedDate(task.created_time), truncate: truncatedResult)
                        }
                    }
                }
            }
        }
    }

    private var headerSubtitle: String {
        if isLoading { return "Loading…" }
        return tasks.count == 1 ? "1 task" : "\(tasks.count) tasks"
    }

    private func formattedDate(_ raw: String) -> String {
        if let date = isoFormatter.date(from: raw)
            ?? isoNoFractionFormatter.date(from: raw)
            ?? noTZDateParser.date(from: raw) {
            return displayFormatter.string(from: date)
        }
        return raw
    }

    private func banner(message: String, isError: Bool) -> some View {
        let tint: Color = isError ? .red : .green
        let icon = isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tint.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private struct TaskTile: View {
        let task: AgentTask
        let formattedRunTime: String
        let formattedCreated: String
        let truncate: (String) -> String

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(task.name)
                    .font(.headline)
                    .foregroundStyle(Color.white)

                detailRow(title: "Schedule", value: task.schedule, system: "calendar")
                detailRow(title: "Next Run", value: formattedRunTime, system: "clock")
                detailRow(title: "Created", value: "\(task.created_by) • \(formattedCreated)", system: "person")

                if let result = task.task_result {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader("Result", subtitle: result.status.capitalized, systemImage: "text.justify")
                        Text(truncate(result.stdout))
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let actions = task.actions, !actions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader("Actions", subtitle: "\(actions.count) defined", systemImage: "bolt.badge.clock")
                        ForEach(actions, id: \.name) { action in
                            HStack(spacing: 8) {
                                Image(systemName: "arrowtriangle.forward.fill")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.cyan)
                                Text("\(action.name) (\(action.type))")
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.8))
                            }
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }

        private func detailRow(title: String, value: String, system: String) -> some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: system)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.cyan)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.uppercased())
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.55))
                    Text(value)
                        .font(.callout)
                        .foregroundStyle(Color.white)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
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
            // Print raw data for debugging
            print("Raw data received: \(String(data: data, encoding: .utf8) ?? "nil")")
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

    private enum CodingKeys: String, CodingKey { case id, field, agent, value }

    init(id: Int, field: Int, agent: Int, value: String) {
        self.id = id
        self.field = field
        self.agent = agent
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(Int.self, forKey: .id)
        self.field = try c.decode(Int.self, forKey: .field)
        self.agent = try c.decode(Int.self, forKey: .agent)
        // Coerce value into String, be tolerant of nulls and non-strings
        if let s = try c.decodeIfPresent(String.self, forKey: .value) {
            self.value = s
        } else if let i = try? c.decode(Int.self, forKey: .value) {
            self.value = String(i)
        } else if let d = try? c.decode(Double.self, forKey: .value) {
            self.value = String(d)
        } else if let b = try? c.decode(Bool.self, forKey: .value) {
            self.value = String(b)
        } else {
            self.value = ""
        }
    }
}

// MARK: – AgentCustomFieldsView
struct AgentCustomFieldsView: View {
    let customFields: [CustomField]

    var body: some View {
        ZStack {
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    headerCard
                    fieldsCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }
        }
        .navigationTitle("Custom Fields")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerCard: some View {
        GlassCard {
            SectionHeader("Custom Fields", subtitle: headerSubtitle, systemImage: "slider.horizontal.3")
        }
    }

    private var fieldsCard: some View {
        GlassCard {
            if customFields.isEmpty {
                Text("No custom fields available for this agent.")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVStack(spacing: 16) {
                    ForEach(customFields) { field in
                        CustomFieldTile(field: field)
                    }
                }
            }
        }
    }

    private var headerSubtitle: String {
        if customFields.isEmpty { return "No records" }
        return customFields.count == 1 ? "1 record" : "\(customFields.count) records"
    }

    private struct CustomFieldTile: View {
        let field: CustomField

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "number")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.cyan)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Record ID")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.6))
                        Text("#\(field.id)")
                            .font(.callout)
                            .foregroundStyle(Color.white)
                    }
                    Spacer(minLength: 0)
                }

                Divider()
                    .background(Color.white.opacity(0.12))

                Text(field.value.nonEmpty ?? "—")
                    .font(.body)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }
}

// MARK: - AgentChecksView

struct AgentChecksView: View {
    let agentId: String
    let baseURL: String
    let apiKey: String

    // shared ISO8601 formatter for parsing last_run
    private static var iso8601Formatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
    // ISO8601 formatter without fractional seconds for dates lacking fractional part
    private static var iso8601NoFractionFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
    private static var noTimeZoneFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }

    @State private var checks: [AgentCheck] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil

    var effectiveAPIKey: String { KeychainHelper.shared.getAPIKey() ?? apiKey }

    private func truncatedOutput(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 600 else { return trimmed }
        let index = trimmed.index(trimmed.startIndex, offsetBy: 600)
        return String(trimmed[..<index]) + "…"
    }

    var body: some View {
        ZStack {
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    headerCard
                    checksListCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }

            if isLoading {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                ProgressView("Loading checks…")
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .navigationTitle("Agent Checks")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await fetchChecks() }
        }
    }

    private var headerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Health Checks", subtitle: headerSubtitle, systemImage: "waveform.path.ecg")
                if let errorMessage {
                    banner(message: errorMessage, isError: true)
                }
            }
        }
    }

    private var checksListCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                if checks.isEmpty && !isLoading && errorMessage == nil {
                    Text("No checks returned for this agent.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(checks) { check in
                            CheckTile(
                                check: check,
                                statusInfo: statusInfo(for: check.check_result?.status),
                                formattedLastRun: formattedDate(check.check_result?.last_run),
                                formattedCreated: formattedDate(check.created_time),
                                truncatedOutput: truncatedOutput
                            )
                        }
                    }
                }
            }
        }
    }

    private var headerSubtitle: String {
        if isLoading { return "Loading…" }
        return checks.count == 1 ? "1 check" : "\(checks.count) checks"
    }

    private func formattedDate(_ raw: String?) -> String {
        guard let raw else { return "Unknown" }
        if let date = Self.iso8601Formatter.date(from: raw)
            ?? Self.iso8601NoFractionFormatter.date(from: raw)
            ?? Self.noTimeZoneFormatter.date(from: raw) {
            return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        }
        return raw
    }

    private func statusInfo(for status: String?) -> (text: String, color: Color, icon: String) {
        let normalized = status?.lowercased() ?? "unknown"
        switch normalized {
        case let value where value.contains("pass"):
            return (text: status?.capitalized ?? "Passing", color: Color.green, icon: "checkmark.circle.fill")
        case let value where value.contains("warn"):
            return (text: status?.capitalized ?? "Warning", color: Color.orange, icon: "exclamationmark.triangle.fill")
        case let value where value.contains("fail") || value.contains("error"):
            return (text: status?.capitalized ?? "Failing", color: Color.red, icon: "xmark.octagon.fill")
        default:
            return (text: status?.capitalized ?? "Unknown", color: Color.gray, icon: "questionmark.circle.fill")
        }
    }

    private func banner(message: String, isError: Bool) -> some View {
        let tint: Color = isError ? .red : .green
        let icon = isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
            Text(message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(tint.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(tint.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private struct CheckTile: View {
        let check: AgentCheck
        let statusInfo: (text: String, color: Color, icon: String)
        let formattedLastRun: String
        let formattedCreated: String
        let truncatedOutput: (String) -> String

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: statusInfo.icon)
                        .font(.title3)
                        .foregroundStyle(statusInfo.color)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(statusInfo.color.opacity(0.18))
                        )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(check.readable_desc)
                            .font(.headline)
                            .foregroundStyle(Color.white)
                        Text(statusInfo.text)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(statusInfo.color)
                    }
                    Spacer(minLength: 0)
                }

                infoRow(title: "Last Run", value: formattedLastRun)
                infoRow(title: "Created", value: "\(check.created_by) • \(formattedCreated)")

                if let severity = check.check_result?.alert_severity?.capitalized, !severity.isEmpty {
                    infoRow(title: "Alert Severity", value: severity)
                }

                if let stdout = check.check_result?.stdout?.nonEmpty {
                    outputSection(title: "Output", value: truncatedOutput(stdout))
                } else if let info = check.check_result?.more_info?.nonEmpty {
                    outputSection(title: "Details", value: truncatedOutput(info))
                }

                if let stderr = check.check_result?.stderr?.nonEmpty {
                    outputSection(title: "Errors", value: truncatedOutput(stderr), isError: true)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .textSelection(.enabled)
        }

        private func infoRow(title: String, value: String) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.55))
                Text(value)
                    .font(.callout)
                    .foregroundStyle(Color.white)
            }
        }

        private func outputSection(title: String, value: String, isError: Bool = false) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title, subtitle: nil, systemImage: isError ? "exclamationmark.octagon" : "doc.plaintext")
                Text(value)
                    .font(.caption.monospaced())
                    .foregroundStyle(isError ? Color.red.opacity(0.9) : Color.white.opacity(0.85))
            }
        }
    }

    @MainActor
    func fetchChecks() async {
        isLoading = true
        errorMessage = nil

        let sanitized = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitized)/agents/\(agentId)/checks/") else {
            errorMessage = "Invalid URL"
            DiagnosticLogger.shared.appendError("Invalid URL in fetching checks.")
            print("Invalid URL in fetching checks.")
            isLoading = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addDefaultHeaders(apiKey: effectiveAPIKey)
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
                guard http.statusCode == 200 else {
                    errorMessage = "HTTP Error: \(http.statusCode)"
                    DiagnosticLogger.shared.appendError("HTTP Error \(http.statusCode) in fetching checks.")
                    print("HTTP Error \(http.statusCode) in fetching checks.")
                    isLoading = false
                    return
                }
            }
            // Print raw data for debugging
            print("Raw data received: \(String(data: data, encoding: .utf8) ?? "nil")")
            // Decode the JSON array of checks directly
            let decoded = try JSONDecoder().decode([AgentCheck].self, from: data)
            checks = decoded
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Error fetching checks: \(error.localizedDescription)")
            print("Error fetching checks: \(error.localizedDescription)")
        }

        isLoading = false
    }


}
