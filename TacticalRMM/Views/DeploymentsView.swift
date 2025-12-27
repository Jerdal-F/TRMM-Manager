import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct DeploymentsView: View {
    let settings: RMMSettings
    @Environment(\.appTheme) private var appTheme

    @State private var deployments: [RMMDeployment] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var clients: [RMMClient] = []
    @State private var isLoadingClients = false
    @State private var clientErrorMessage: String?
    @State private var showCreateDeployment = false
    @State private var selectedClientID: Int?
    @State private var selectedSiteID: Int?
    @State private var selectedAgentType: AgentType = .server
    @State private var expiresAt: Date = Date().addingTimeInterval(30 * 24 * 60 * 60)
    @State private var enableRDP = false
    @State private var enablePing = false
    @State private var enablePower = false
    @State private var selectedArchitecture: Architecture = .amd64
    @State private var createErrorMessage: String?
    @State private var isCreatingDeployment = false
    @State private var deleteErrorMessage: String?
    @State private var deletingDeploymentIDs: Set<Int> = []
    @State private var deploymentPendingDeletion: RMMDeployment?
    @State private var showDeleteConfirmation = false

    var body: some View {
        ZStack {
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 18) {
                            SectionHeader("Deployments", subtitle: "Manage deployments for this instance", systemImage: "shippingbox.circle.fill")

                            Button {
                                showCreateDeployment = true
                            } label: {
                                Label("New Deployment", systemImage: "plus")
                                    .frame(maxWidth: .infinity)
                            }
                            .primaryButton()

                            if let deleteErrorMessage {
                                Text(deleteErrorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(Color.red)
                            }

                            if isLoading && deployments.isEmpty {
                                HStack {
                                    ProgressView()
                                    Text("Loading deployments…")
                                        .font(.footnote)
                                        .foregroundStyle(Color.white.opacity(0.7))
                                }
                            } else if let errorMessage {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(errorMessage)
                                        .font(.footnote)
                                        .foregroundStyle(Color.red)
                                    Button {
                                        Task { await loadDeployments(force: true) }
                                    } label: {
                                        Label("Retry", systemImage: "arrow.clockwise")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .primaryButton()
                                }
                            } else if deployments.isEmpty {
                                Text("No deployments found.")
                                    .font(.footnote)
                                    .foregroundStyle(Color.white.opacity(0.7))
                            } else {
                                LazyVStack(spacing: 14) {
                                    ForEach(deployments) { deployment in
                                        deploymentRow(for: deployment)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }
        }
        .navigationTitle("Deployments")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadDeployments(force: true)
            await loadClients(force: true)
        }
        .refreshable {
            await loadDeployments(force: true)
            await loadClients(force: true)
        }
        .sheet(isPresented: $showCreateDeployment) {
            createDeploymentSheet()
        }
        .confirmationDialog(
            "Delete deployment?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible,
            presenting: deploymentPendingDeletion
        ) { deployment in
            Button("Delete", role: .destructive) {
                showDeleteConfirmation = false
                deploymentPendingDeletion = nil
                Task { await deleteDeployment(deployment) }
            }
            Button("Cancel", role: .cancel) {
                showDeleteConfirmation = false
                deploymentPendingDeletion = nil
            }
        } message: { deployment in
            Text("Are you sure you want to delete the deployment for \(deployment.displayTitle)?")
        }
        .onChange(of: selectedClientID) { _, newValue in
            updateSiteSelection(for: newValue)
        }
    }

    private func createDeploymentSheet() -> some View {
        NavigationStack {
            ZStack {
                DarkGradientBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        SectionHeader("New Deployment", subtitle: "Create an installer", systemImage: "shippingbox")

                        if isLoadingClients && clients.isEmpty {
                            HStack {
                                ProgressView()
                                Text("Loading clients…")
                                    .font(.footnote)
                                    .foregroundStyle(Color.white.opacity(0.7))
                            }
                        } else if let clientErrorMessage {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(clientErrorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(Color.red)
                                Button {
                                    Task { await loadClients(force: true) }
                                } label: {
                                    Label("Retry", systemImage: "arrow.clockwise")
                                        .frame(maxWidth: .infinity)
                                }
                                .primaryButton()
                            }
                        } else {
                            clientPickers()

                            agentTypePicker()

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Expiry")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.white.opacity(0.6))
                                    .kerning(1.2)
                                DatePicker(
                                    "",
                                    selection: $expiresAt,
                                    displayedComponents: [.date, .hourAndMinute]
                                )
                                .environment(\.timeZone, TimeZone.current)
                                .datePickerStyle(.compact)
                                .labelsHidden()
                            }
                            .padding(.vertical, 4)

                            Toggle(isOn: $enableRDP) {
                                Text("Enable RDP")
                                    .font(.callout)
                                    .foregroundStyle(Color.white)
                            }
                            .toggleStyle(SwitchToggleStyle(tint: appTheme.accent))

                            Toggle(isOn: $enablePing) {
                                Text("Enable Ping")
                                    .font(.callout)
                                    .foregroundStyle(Color.white)
                            }
                            .toggleStyle(SwitchToggleStyle(tint: appTheme.accent))

                            Toggle(isOn: $enablePower) {
                                Text("Enable Power")
                                    .font(.callout)
                                    .foregroundStyle(canTogglePower ? Color.white : Color.white.opacity(0.4))
                            }
                            .toggleStyle(SwitchToggleStyle(tint: appTheme.accent))
                            .disabled(!canTogglePower)

                            architecturePicker()
                        }

                        if let createErrorMessage {
                            Text(createErrorMessage)
                                .font(.footnote)
                                .foregroundStyle(Color.red)
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle("New Deployment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showCreateDeployment = false
                    }
                    .foregroundStyle(appTheme.accent)
                    .disabled(isCreatingDeployment)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await createDeployment() }
                    }
                    .foregroundStyle(appTheme.accent)
                    .disabled(isCreatingDeployment || selectedSiteID == nil)
                }
            }
            .task {
                if clients.isEmpty {
                    await loadClients(force: true)
                }
                ensureDefaultSelections()
            }
            .onChange(of: selectedAgentType) { _, newValue in
                if newValue == .server {
                    enablePower = false
                }
            }
            .onDisappear {
                resetCreateForm()
            }
        }
    }

    @ViewBuilder
    private func clientPickers() -> some View {
        VStack(alignment: .leading, spacing: 18) {
            selectionMenu(
                title: "Client",
                value: selectedClientName,
                placeholder: clients.isEmpty ? "No clients available" : "Select a client",
                disabled: clients.isEmpty
            ) {
                Button("Clear Selection", role: .destructive) {
                    selectedClientID = nil
                    selectedSiteID = nil
                }
                ForEach(clients.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { client in
                    Button(client.name) {
                        selectedClientID = client.id
                    }
                }
            }

            selectionMenu(
                title: "Site",
                value: selectedSiteName,
                placeholder: selectedClientID == nil ? "Select a client first" : "Select a site",
                disabled: selectedSites.isEmpty
            ) {
                Button("Clear Selection", role: .destructive) {
                    selectedSiteID = nil
                }
                ForEach(selectedSites.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { site in
                    Button(site.name) {
                        selectedSiteID = site.id
                    }
                }
            }

            if selectedClientID != nil && selectedSites.isEmpty {
                Text("No sites available for this client.")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
    }

    @ViewBuilder
    private func agentTypePicker() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent Type")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.6))
                .kerning(1.2)
            Picker("Agent Type", selection: $selectedAgentType) {
                ForEach(AgentType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private func architecturePicker() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Architecture")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.6))
                .kerning(1.2)
            Picker("Architecture", selection: $selectedArchitecture) {
                ForEach(Architecture.allCases, id: \.self) { arch in
                    Text(arch.displayName).tag(arch)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var selectedSites: [RMMClientSite] {
        guard let clientID = selectedClientID else { return [] }
        return clients.first(where: { $0.id == clientID })?.sites ?? []
    }

    private var selectedClientName: String {
        guard let clientID = selectedClientID,
              let client = clients.first(where: { $0.id == clientID }) else { return "" }
        return client.name
    }

    private var selectedSiteName: String {
        guard let siteID = selectedSiteID,
              let site = selectedSites.first(where: { $0.id == siteID }) else { return "" }
        return site.name
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

    private var canTogglePower: Bool {
        selectedAgentType != .server
    }

    private enum AgentType: String, CaseIterable {
        case server
        case workstation

        var displayName: String {
            switch self {
            case .server:
                return "Server"
            case .workstation:
                return "Workstation"
            }
        }
    }

    private enum Architecture: String, CaseIterable {
        case amd64 = "amd64"
        case i386 = "386"

        var displayName: String {
            switch self {
            case .amd64:
                return "64 bit"
            case .i386:
                return "32 bit"
            }
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter
    }()

    private func deploymentRow(for deployment: RMMDeployment) -> some View {
        let isDeleting = deletingDeploymentIDs.contains(deployment.id)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(deployment.displayTitle)
                        .font(.headline)
                    Text("UID: \(deployment.uid)")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.65))
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 10) {
                    VStack(alignment: .trailing, spacing: 6) {
                        capsuleBadge(text: deployment.monType.uppercased(), tint: appTheme.accent.opacity(0.2))
                        capsuleBadge(text: deployment.goArch.uppercased(), tint: Color.white.opacity(0.1))
                    }

                    Button {
                        deploymentPendingDeletion = deployment
                        showDeleteConfirmation = true
                    } label: {
                        Group {
                            if isDeleting {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "trash")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isDeleting ? Color.white.opacity(0.6) : Color.red)
                    .disabled(isDeleting)
                    .accessibilityLabel("Delete deployment")
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                infoRow(icon: "calendar.badge.exclamationmark", title: "Expires", value: deployment.expiryDisplayText)
                infoRow(icon: "clock.arrow.circlepath", title: "Created", value: deployment.createdDisplayText)
            }

            if let flags = deployment.installFlags {
                HStack(spacing: 8) {
                    capsuleBadge(text: flags.rdp == true ? "RDP" : "RDP OFF", tint: flags.rdp == true ? Color.green.opacity(0.22) : Color.white.opacity(0.08))
                    capsuleBadge(text: flags.ping == true ? "PING" : "PING OFF", tint: flags.ping == true ? Color.green.opacity(0.22) : Color.white.opacity(0.08))
                    capsuleBadge(text: flags.power == true ? "POWER" : "POWER OFF", tint: flags.power == true ? Color.green.opacity(0.22) : Color.white.opacity(0.08))
                }
            }

            Button {
                copyDeploymentLink(deployment)
            } label: {
                Label("Copy Download Link", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .secondaryButton()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(appTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.6))
                Text(value)
                    .font(.callout)
                    .foregroundStyle(Color.white)
            }
        }
    }

    private func capsuleBadge(text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(tint)
            )
    }

    private func ensureDefaultSelections() {
        if selectedClientID == nil, let firstClient = clients.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }).first {
            selectedClientID = firstClient.id
        }

        updateSiteSelection(for: selectedClientID)

        if selectedSiteID == nil, let firstSite = selectedSites.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }).first {
            selectedSiteID = firstSite.id
        }
    }

    private func updateSiteSelection(for clientID: Int?) {
        let availableSites = sites(for: clientID)
        guard !availableSites.isEmpty else {
            selectedSiteID = nil
            return
        }

        if let current = selectedSiteID, availableSites.contains(where: { $0.id == current }) {
            return
        }

        selectedSiteID = availableSites.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.first?.id
    }

    private func sites(for clientID: Int?) -> [RMMClientSite] {
        guard let clientID else { return [] }
        return clients.first(where: { $0.id == clientID })?.sites ?? []
    }

    private func resetCreateForm() {
        expiresAt = Date().addingTimeInterval(30 * 24 * 60 * 60)
        enableRDP = false
        enablePing = false
        enablePower = false
        selectedAgentType = .server
        selectedArchitecture = .amd64
        createErrorMessage = nil
        isCreatingDeployment = false
    }

    @MainActor
    private func createDeployment() async {
        guard let siteID = selectedSiteID else {
            createErrorMessage = "Select a site before creating a deployment."
            return
        }

        if settings.baseURL.isDemoEntry {
            createDemoDeployment(siteID: siteID)
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            createErrorMessage = "Missing API key for this instance."
            return
        }

        let base = settings.baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(base)/clients/deployments/") else {
            createErrorMessage = "Invalid base URL."
            return
        }

        let payload = DeploymentCreatePayload(
            site: siteID,
            expires: DeploymentsView.isoFormatter.string(from: expiresAt),
            agenttype: selectedAgentType.rawValue,
            power: enablePower,
            rdp: enableRDP,
            ping: enablePing,
            goarch: selectedArchitecture.rawValue
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.addDefaultHeaders(apiKey: apiKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(payload)
        } catch {
            createErrorMessage = "Failed to encode deployment request."
            DiagnosticLogger.shared.appendError("Failed to encode deployment payload: \(error.localizedDescription)")
            return
        }

        isCreatingDeployment = true
        createErrorMessage = nil
        defer { isCreatingDeployment = false }

        DiagnosticLogger.shared.logHTTPRequest(
            method: "POST",
            url: url.absoluteString,
            headers: request.allHTTPHeaderFields ?? [:]
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                createErrorMessage = "Unexpected response while creating deployment."
                DiagnosticLogger.shared.appendError("Deployment creation response missing HTTPURLResponse.")
                return
            }

            DiagnosticLogger.shared.logHTTPResponse(
                method: "POST",
                url: url.absoluteString,
                status: http.statusCode,
                data: data
            )

            switch http.statusCode {
            case 200, 201:
                DiagnosticLogger.shared.append("Created deployment \(selectedAgentType.rawValue) for site \(siteID)")
                await loadDeployments(force: true)
                resetCreateForm()
                showCreateDeployment = false
            case 400:
                createErrorMessage = "Deployment rejected by server."
            case 401:
                createErrorMessage = "Invalid API key or insufficient permissions."
            case 403:
                createErrorMessage = "You do not have permission to create deployments."
            default:
                createErrorMessage = "HTTP \(http.statusCode) while creating deployment."
            }
        } catch {
            createErrorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Failed to create deployment: \(error.localizedDescription)")
        }
    }

    private func deleteDeployment(_ deployment: RMMDeployment) async {
        let deploymentID = deployment.id

        let alreadyDeleting = await MainActor.run { deletingDeploymentIDs.contains(deploymentID) }
        if alreadyDeleting { return }

        await MainActor.run {
            deletingDeploymentIDs.insert(deploymentID)
            deleteErrorMessage = nil
        }

        if settings.baseURL.isDemoEntry {
            await MainActor.run {
                withAnimation {
                    deployments.removeAll { $0.id == deploymentID }
                }
                deletingDeploymentIDs.remove(deploymentID)
            }
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            await MainActor.run {
                deleteErrorMessage = "Missing API key for this instance."
                deletingDeploymentIDs.remove(deploymentID)
            }
            return
        }

        let base = settings.baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(base)/clients/deployments/\(deploymentID)/") else {
            await MainActor.run {
                deleteErrorMessage = "Invalid base URL."
                deletingDeploymentIDs.remove(deploymentID)
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 45
        request.addDefaultHeaders(apiKey: apiKey)

        DiagnosticLogger.shared.logHTTPRequest(
            method: "DELETE",
            url: url.absoluteString,
            headers: request.allHTTPHeaderFields ?? [:]
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                await MainActor.run {
                    deleteErrorMessage = "Unexpected response while deleting deployment."
                    deletingDeploymentIDs.remove(deploymentID)
                }
                DiagnosticLogger.shared.appendError("Deployment delete response missing HTTPURLResponse.")
                return
            }

            DiagnosticLogger.shared.logHTTPResponse(
                method: "DELETE",
                url: url.absoluteString,
                status: http.statusCode,
                data: data
            )

            switch http.statusCode {
            case 200, 202, 204:
                await MainActor.run {
                    withAnimation {
                        deployments.removeAll { $0.id == deploymentID }
                    }
                    deletingDeploymentIDs.remove(deploymentID)
                }
                DiagnosticLogger.shared.append("Deleted deployment id \(deploymentID)")
            case 404:
                await MainActor.run {
                    deleteErrorMessage = "Deployment not found on server."
                    withAnimation {
                        deployments.removeAll { $0.id == deploymentID }
                    }
                    deletingDeploymentIDs.remove(deploymentID)
                }
            case 401:
                await MainActor.run {
                    deleteErrorMessage = "Invalid API key or insufficient permissions."
                    deletingDeploymentIDs.remove(deploymentID)
                }
            case 403:
                await MainActor.run {
                    deleteErrorMessage = "You do not have permission to delete deployments."
                    deletingDeploymentIDs.remove(deploymentID)
                }
            default:
                let serverMessage = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    if let serverMessage, !serverMessage.isEmpty {
                        deleteErrorMessage = serverMessage
                    } else {
                        deleteErrorMessage = "HTTP \(http.statusCode) while deleting deployment."
                    }
                    deletingDeploymentIDs.remove(deploymentID)
                }
            }
        } catch {
            await MainActor.run {
                deleteErrorMessage = error.localizedDescription
                deletingDeploymentIDs.remove(deploymentID)
            }
            DiagnosticLogger.shared.appendError("Failed to delete deployment: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func loadClients(force: Bool = false) async {
        if isLoadingClients && !force { return }

        if settings.baseURL.isDemoEntry {
            loadDemoClients()
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            clientErrorMessage = "Missing API key for this instance."
            clients = []
            return
        }

        let base = settings.baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(base)/clients/") else {
            clientErrorMessage = "Invalid base URL."
            clients = []
            return
        }

        isLoadingClients = true
        clientErrorMessage = nil
        defer { isLoadingClients = false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        request.addDefaultHeaders(apiKey: apiKey)

        DiagnosticLogger.shared.logHTTPRequest(
            method: "GET",
            url: url.absoluteString,
            headers: request.allHTTPHeaderFields ?? [:]
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                clientErrorMessage = "Unexpected response while loading clients."
                DiagnosticLogger.shared.appendError("Clients response missing HTTPURLResponse.")
                clients = []
                return
            }

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
                    let decoded = try decoder.decode([RMMClient].self, from: data)
                    clients = decoded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    clientErrorMessage = nil
                    ensureDefaultSelections()
                } catch {
                    clientErrorMessage = "Failed to decode clients."
                    clients = []
                    DiagnosticLogger.shared.appendError("Failed to decode clients: \(error.localizedDescription)")
                }
            case 403:
                clientErrorMessage = "You do not have permission to fetch clients."
                clients = []
                selectedClientID = nil
                selectedSiteID = nil
            case 401:
                clientErrorMessage = "Invalid API key or insufficient permissions."
                clients = []
                selectedClientID = nil
                selectedSiteID = nil
            default:
                clientErrorMessage = "HTTP \(http.statusCode) while loading clients."
                clients = []
                selectedClientID = nil
                selectedSiteID = nil
            }
        } catch {
            if error.isCancelledRequest {
                return
            }
            clientErrorMessage = error.localizedDescription
            clients = []
            DiagnosticLogger.shared.appendError("Failed to load clients: \(error.localizedDescription)")
            selectedClientID = nil
            selectedSiteID = nil
        }
    }

    @MainActor
    private func loadDeployments(force: Bool = false) async {
        guard !isLoading || force else { return }

        deleteErrorMessage = nil

        if settings.baseURL.isDemoEntry {
            loadDemoDeployments()
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            errorMessage = "Missing API key for this instance."
            deployments = []
            return
        }

        let base = settings.baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(base)/clients/deployments/") else {
            errorMessage = "Invalid base URL."
            deployments = []
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        request.addDefaultHeaders(apiKey: apiKey)

        DiagnosticLogger.shared.logHTTPRequest(
            method: "GET",
            url: url.absoluteString,
            headers: request.allHTTPHeaderFields ?? [:]
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                errorMessage = "Unexpected response while loading deployments."
                DiagnosticLogger.shared.appendError("Deployments response missing HTTPURLResponse.")
                deployments = []
                return
            }

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
                    let decoded = try decoder.decode([RMMDeployment].self, from: data)
                    deployments = decoded
                } catch {
                    errorMessage = "Failed to decode deployments."
                    deployments = []
                    DiagnosticLogger.shared.appendError("Failed to decode deployments: \(error.localizedDescription)")
                }
            case 403:
                errorMessage = "You do not have permission to manage deployments."
                deployments = []
            case 401:
                errorMessage = "Invalid API key or insufficient permissions."
                deployments = []
            default:
                errorMessage = "HTTP \(http.statusCode) while loading deployments."
                deployments = []
            }
        } catch {
            if error.isCancelledRequest {
                return
            }
            errorMessage = error.localizedDescription
            deployments = []
            DiagnosticLogger.shared.appendError("Failed to load deployments: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func loadDemoDeployments() {
        isLoading = false
        errorMessage = nil
        deleteErrorMessage = nil
        deployments = [
            RMMDeployment(
                id: 14,
                uid: "DEMO-UID-001",
                clientID: 1,
                siteID: 1,
                clientName: "Demo Client",
                siteName: "Demo Site",
                monType: "server",
                goArch: "amd64",
                expiry: DeploymentsView.isoFormatter.string(from: Date().addingTimeInterval(86400)),
                installFlags: RMMDeployment.InstallFlags(rdp: false, ping: true, power: false),
                created: DeploymentsView.isoFormatter.string(from: Date().addingTimeInterval(-7200))
            )
        ]
    }

    @MainActor
    private func copyDeploymentLink(_ deployment: RMMDeployment) {
        let base = settings.baseURL.removingTrailingSlash()
        let link = "\(base)/clients/\(deployment.uid)/deploy/"

        #if canImport(UIKit)
        UIPasteboard.general.string = link
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        #endif

    }

    @MainActor
    private func loadDemoClients() {
        isLoadingClients = false
        clientErrorMessage = nil
        clients = [
            RMMClient(
                id: 1,
                name: "Demo Client",
                sites: [
                    RMMClientSite(id: 1, name: "Demo Site", clientID: 1, clientName: "Demo Client"),
                    RMMClientSite(id: 2, name: "Testing", clientID: 1, clientName: "Demo Client")
                ]
            )
        ]
        ensureDefaultSelections()
    }

    @MainActor
    private func createDemoDeployment(siteID: Int) {
        let allSites = clients.flatMap { $0.sites }
        let site = allSites.first(where: { $0.id == siteID })
        let client = clients.first(where: { $0.id == site?.clientID })

        let newDeployment = RMMDeployment(
            id: (deployments.max(by: { $0.id < $1.id })?.id ?? 0) + 1,
            uid: UUID().uuidString.lowercased(),
            clientID: client?.id ?? 0,
            siteID: siteID,
            clientName: client?.name ?? "Demo Client",
            siteName: site?.name ?? "Demo Site",
            monType: selectedAgentType.rawValue,
            goArch: selectedArchitecture.rawValue,
            expiry: DeploymentsView.isoFormatter.string(from: expiresAt),
            installFlags: RMMDeployment.InstallFlags(rdp: enableRDP, ping: enablePing, power: enablePower),
            created: DeploymentsView.isoFormatter.string(from: Date())
        )

        deployments.insert(newDeployment, at: 0)
        showCreateDeployment = false
        resetCreateForm()
    }
}

private struct DeploymentCreatePayload: Encodable {
    let site: Int
    let expires: String
    let agenttype: String
    let power: Bool
    let rdp: Bool
    let ping: Bool
    let goarch: String
}
