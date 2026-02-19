import SwiftUI
import SwiftData
import LocalAuthentication
import UIKit
#if canImport(AppKit)
import AppKit
#endif
import StoreKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appTheme) private var appTheme
    @Environment(\.openURL) private var openURL
    @Query private var settingsList: [RMMSettings]
    @ObservedObject private var agentCache = AgentCache.shared
    @ObservedObject private var localizationDebug = LocalizationDebugState.shared

    @AppStorage("hideSensitive") private var hideSensitiveInfo: Bool = false
    @AppStorage("hideCommunityScripts") private var hideCommunityScripts: Bool = false
    @AppStorage("useFaceID") private var useFaceID: Bool = false
    @AppStorage("activeSettingsUUID") private var activeSettingsUUID: String = ""
    @AppStorage("lastSeenDateFormat") private var lastSeenDateFormat: String = ""
    @AppStorage("skippedUpdateVersion") private var skippedUpdateVersion: String = ""
    @ObservedObject private var demoMode = DemoModeState.shared
    @State private var showGuideAlert = false
    @State private var showDiagnosticAlert = false
    @State private var showLogShareSheet = false
    @State private var showSettings = false
    @State private var showRecoveryAlert = false
    @State private var showUpdateAlert = false
    @State private var showApiEndpointAlert = false
    @State private var latestVersion: String = ""

    @State private var isAuthenticating = false
    @State private var didAuthenticate = false

    @State private var showServerSettings = false
    @State private var selectedServerSettings: RMMSettings?

    @State private var agents: [Agent] = []
    @State private var displayedAgents: [Agent] = []
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
    @State private var agentFilterTask: Task<Void, Never>?
    @State private var searchDebounceTask: Task<Void, Never>?

    private var faceIDEnabled: Bool {
        useFaceID && !ProcessInfo.processInfo.isiOSAppOnMac
    }

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
                .scrollContentBackground(.hidden)
                .background(Color.clear)
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
                        .foregroundStyle(appTheme.accent)
                        .disabled(faceIDEnabled && !didAuthenticate)
                    }
                }
                .keyboardDismissToolbar()
                .navigationDestination(isPresented: $showServerSettings) {
                    if let settings = selectedServerSettings {
                        ServerSettingsView(settings: settings)
                    } else {
                        EmptyView()
                    }
                }
            }
            .background(Color.clear)
            .alert("Diagnostics", isPresented: $showDiagnosticAlert) {
                Button("Save", role: .destructive) { showLogShareSheet = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Export diagnostics log? It may include sensitive information.")
            }
            .onAppear {
                DiagnosticLogger.shared.append("ContentView onAppear")
                if ProcessInfo.processInfo.isiOSAppOnMac {
                    useFaceID = false
                }
                if agents.isEmpty, !agentCache.agents.isEmpty {
                    agents = agentCache.agents
                    updateDisplayedAgents()
                }
                if !faceIDEnabled {
                    loadInitialSettings()
                }
                startTransactionUpdatesIfNeeded()
                Task { await checkForUpdateIfNeeded() }
            }
            .onChange(of: activeSettingsUUID) { _, _ in
                applyActiveSettings()
                resetAgentsForInstanceChange()
            }
            .onChange(of: settingsList.map { $0.uuid }) { _, _ in
                if settingsList.isEmpty {
                    activeSettingsUUID = ""
                } else if !settingsList.contains(where: { $0.uuid.uuidString == activeSettingsUUID }) {
                    activeSettingsUUID = settingsList.first?.uuid.uuidString ?? ""
                }
                applyActiveSettings()
                resetAgentsForInstanceChange()
            }
            .onChange(of: appliedSearchText) { _, _ in
                updateDisplayedAgents()
            }
            .onChange(of: sortOption) { _, _ in
                updateDisplayedAgents()
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("reloadAgents"))) { notification in
                guard !(faceIDEnabled && !didAuthenticate) else { return }
                applyActiveSettings()
                resetAgentsForInstanceChange()
            }
            .onReceive(NotificationCenter.default.publisher(for: .forceUpdateCheck)) { _ in
                Task { await checkForUpdateIfNeeded(force: true) }
            }
            .onDisappear {
                transactionUpdatesTask?.cancel()
                transactionUpdatesTask = nil
                agentFilterTask?.cancel()
                agentFilterTask = nil
                searchDebounceTask?.cancel()
                searchDebounceTask = nil
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .background:
                    didAuthenticate = false
                    KeychainHelper.shared.clearCachedKeys()

                case .inactive:
                    // Keep authentication alive during transient system overlays (e.g. StoreKit purchase sheet).
                    break

                case .active:
                    guard faceIDEnabled, !didAuthenticate else { return }

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
                if ProcessInfo.processInfo.isiOSAppOnMac {
                    useFaceID = false
                    return
                }
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

            if faceIDEnabled && !didAuthenticate {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()

                    Color.black.opacity(0.4)
                        .ignoresSafeArea()

                    ProgressView(isAuthenticating ? L10n.key("faceid.authenticating") : L10n.key("faceid.locked"))
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
                        title: Text(L10n.key("faceid.recovery.title")),
                        message: Text(L10n.key("faceid.recovery.message")),
                        dismissButton: .destructive(
                            Text(L10n.key("faceid.recovery.clearButton")),
                            action: clearAppData
                        )
                    )
                }
            }
        }
        .settingsPresentation(
            isPresented: Binding(
                get: { showSettings && !(faceIDEnabled && !didAuthenticate) },
                set: { showSettings = $0 }
            ),
            fullScreen: ProcessInfo.processInfo.isiOSAppOnMac
        ) {
            SettingsView()
        }
        .alert(L10n.key("common.notice"), isPresented: $showUpdateAlert) {
            Button(L10n.key("common.update")) {
                if let url = URL(string: "https://apps.apple.com/gb/app/trmm-manager/id6742686284") {
                    openURL(url)
                }
            }
            Button(L10n.key("common.dismiss"), role: .cancel) {
                skippedUpdateVersion = latestVersion
            }
        } message: {
            Text(L10n.format("update.available.message", latestVersion))
        }
            .alert(L10n.key("connection.endpoint.alert.title"), isPresented: $showApiEndpointAlert) {
                Button(L10n.key("connection.endpoint.alert.help")) {
                    if let url = URL(string: "https://trmm-manager.jerdal.no") {
                        openURL(url)
                    }
                }
                Button(L10n.key("common.dismiss"), role: .cancel) { }
            } message: {
                Text(L10n.key("connection.endpoint.alert.message"))
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
        .onChange(of: showServerSettings) { _, isPresented in
            if !isPresented {
                selectedServerSettings = nil
            }
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

                Text("Press and hold the title to export diagnostics.")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.5))

                if !agents.isEmpty {
                    let onlineCount = agents.filter { $0.isOnlineStatus }.count
                    let offlineCount = agents.filter { $0.isOfflineStatus }.count

                    Divider()
                        .overlay(Color.white.opacity(0.08))

                    ResponsiveBadgeRow(badges: [
                        .init(title: String(localized: "agents.title"), value: String(agents.count), symbol: "desktopcomputer"),
                        .init(title: L10n.key("agents.summary.online"), value: String(onlineCount), symbol: "bolt.horizontal.circle"),
                        .init(title: L10n.key("agents.summary.overdue"), value: String(offlineCount), symbol: "moon.zzz")
                    ])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var connectionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(
                    String(localized: "connection.title"),
                    subtitle: String(localized: "connection.subtitle.secure"),
                    systemImage: "lock.shield"
                )

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
                        VStack(spacing: 12) {
                            refreshButton(for: saved)
                            serverSettingsButton(for: saved)
                        }
                    } else {
                        Text(L10n.key("connection.apiKeyMissingRefresh"))
                            .font(.footnote)
                            .foregroundStyle(Color.red)

                        Button {
                            showSettings = true
                        } label: {
                            Label(L10n.key("connection.updateCredentials"), systemImage: "key.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .primaryButton()

                        serverSettingsButton(for: saved)
                    }
                } else {
                    Text(L10n.key("connection.activeInstance.missing"))
                        .font(.footnote)
                        .foregroundStyle(Color.red)

                    Button {
                        showSettings = true
                    } label: {
                        Label(L10n.key("settings.instances.manage"), systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .primaryButton()
                }

                if !settingsList.isEmpty {
                    Text(L10n.key("agents.note.largeEnvironment"))
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
        }
    }

    @ViewBuilder
    private func refreshButton(for settings: RMMSettings) -> some View {
        let buttonTitleKey = agents.isEmpty ? "agents.fetch" : "agents.refresh"
        Button {
            DiagnosticLogger.shared.append("Login tapped.")
            Task { await fetchAgents(using: settings) }
        } label: {
            Label(LocalizedStringKey(buttonTitleKey), systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
        }
        .primaryButton()
    }

    @ViewBuilder
    private func serverSettingsButton(for settings: RMMSettings) -> some View {
        Button {
            let resolved = ensureIdentifiers(for: settings)
            selectedServerSettings = resolved
            showServerSettings = true
        } label: {
            Label(L10n.key("settings.serverOptions"), systemImage: "gearshape")
                .frame(maxWidth: .infinity)
        }
        .primaryButton()
        .disabled(faceIDEnabled && !didAuthenticate)
    }

    @ViewBuilder
    private func connectionSummary(for settings: RMMSettings) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            let displayName = demoMode.isEnabled
                ? L10n.key("connection.summary.instance.demo")
                : settings.displayName
            summaryRow(title: L10n.key("connection.summary.instanceLabel"), value: displayName, systemImage: "server.rack")
            Text(L10n.key("connection.summary.manageDetails"))
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.65))
        }
    }

    @ViewBuilder
    private func summaryRow(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(appTheme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
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
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .topTrailing) {
                    SectionHeader(
                        String(localized: "agents.title"),
                        subtitle: agentsSubtitle,
                        systemImage: "list.bullet.rectangle"
                    )

                    if !agents.isEmpty || isLoading {
                        HStack(spacing: 10) {
                            Menu {
                                Picker(L10n.key("agents.sort.picker"), selection: $sortOption) {
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
                            .foregroundStyle(appTheme.accent)
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
                            .foregroundStyle(appTheme.accent)
                        }
                        .padding(.top, 2)
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
                                searchDebounceTask?.cancel()
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                searchDebounceTask = Task { [trimmed] in
                                    try? await Task.sleep(nanoseconds: 200_000_000)
                                    if Task.isCancelled { return }
                                    await MainActor.run {
                                        appliedSearchText = trimmed
                                    }
                                }
                            }

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showSearch = false
                                searchText = ""
                                appliedSearchText = ""
                                searchFieldIsFocused = false
                                searchDebounceTask?.cancel()
                                searchDebounceTask = nil
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                    }
                }

                if isLoading && displayedAgents.isEmpty {
                    ProgressView("Loading agents…")
                        .progressViewStyle(.circular)
                        .tint(appTheme.accent)
                } else if let error = errorMessage {
                    Text(L10n.format("Error: %@", error))
                        .foregroundStyle(Color.red)
                        .font(.footnote)
                } else if displayedAgents.isEmpty {
                    Text(agentEmptyMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else {
                    if isLoading {
                        ProgressView("Refreshing agents…")
                            .progressViewStyle(.circular)
                            .tint(appTheme.accent)
                    }
                    LazyVStack(spacing: 16) {
                        ForEach(displayedAgents) { agent in
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
        @Environment(\.appTheme) private var appTheme

        var body: some View {
            GeometryReader { proxy in
                let spacing: CGFloat = 12
                let columnWidth = (proxy.size.width - (spacing * 2)) / 3

                HStack(spacing: spacing) {
                    ForEach(badges) { badge in
                        badgeView(for: badge)
                            .frame(width: columnWidth, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 68)
        }

        @ViewBuilder
        private func badgeView(for badge: BadgeInfo) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: badge.symbol)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(appTheme.accent)
                    Text(badge.title.uppercased())
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                }
                .frame(minHeight: 16, alignment: .leading)
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
        let displayed = displayedAgents.count
        if displayed == total && appliedSearchText.isEmpty && sortOption == .none {
            return total == 1
                ? L10n.format("agents.count.single", total)
                : L10n.format("agents.count.multipleFormat", total)
        }
        return L10n.format("agents.count.filteredFormat", displayed, total)
    }

    @MainActor
    private func updateDisplayedAgents() {
        agentFilterTask?.cancel()
        let agentsSnapshot = agents
        let query = appliedSearchText.lowercased()
        let selectedSort = sortOption
        agentFilterTask = Task.detached(priority: .userInitiated) {
            if Task.isCancelled { return }
            var working = agentsSnapshot.filter { selectedSort.matches($0) }
            if !query.isEmpty {
                working = working.filter {
                    $0.hostname.lowercased().contains(query) ||
                    $0.operating_system.lowercased().contains(query) ||
                    ($0.description?.lowercased().contains(query) ?? false)
                }
            }
            if Task.isCancelled { return }
            let sorted: [Agent]
            switch selectedSort {
            case .none:
                sorted = working.sorted {
                    $0.hostname.localizedCaseInsensitiveCompare($1.hostname) == .orderedAscending
                }
            case .online:
                sorted = working.sorted { lhs, rhs in
                    if lhs.isOnlineStatus == rhs.isOnlineStatus {
                        return lhs.hostname.localizedCaseInsensitiveCompare(rhs.hostname) == .orderedAscending
                    }
                    return lhs.isOnlineStatus && !rhs.isOnlineStatus
                }
            default:
                sorted = working.sorted { lhs, rhs in
                    let left = selectedSort.sortKey(for: lhs)
                    let right = selectedSort.sortKey(for: rhs)
                    if left == right {
                        return lhs.hostname.localizedCaseInsensitiveCompare(rhs.hostname) == .orderedAscending
                    }
                    return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
                }
            }
            if Task.isCancelled { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    displayedAgents = sorted
                }
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

    private var agentEmptyMessage: String {
        if agents.isEmpty {
            return String(localized: "No agents loaded. Save your connection to begin.")
        }
        if !appliedSearchText.isEmpty {
            return String(localized: "No agents match your search.")
        }
        if sortOption != .none {
            return "No agents match your filter."
        }
        return "No agents available."
    }

    private var agentsSubtitle: String? {
        if agents.isEmpty {
            return isLoading ? nil : String(localized: "agents.subtitle.connectEstate")
        }
        return agentCountText
    }

    // MARK: – Helper Methods

    private func resetAgentsForInstanceChange() {
        withAnimation(.easeInOut(duration: 0.2)) {
            agents.removeAll()
            displayedAgents.removeAll()
            errorMessage = nil
            isLoading = false
            searchText = ""
            appliedSearchText = ""
        }
        agentFilterTask?.cancel()
        agentFilterTask = nil
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
    }

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

    private func checkForUpdateIfNeeded() async {
        await checkForUpdateIfNeeded(force: false)
    }

    private func checkForUpdateIfNeeded(force: Bool) async {
        guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return
        }
        if !force, !skippedUpdateVersion.isEmpty, skippedUpdateVersion == current {
            return
        }

        let bundleID = "jerdal.TacticalRMM-Manager"
        guard let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(bundleID)") else {
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return
            }

            guard let lookup = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = lookup["results"] as? [[String: Any]],
                  let latest = results.first?["version"] as? String else {
                return
            }

            if !force, !isVersion(latest, greaterThan: current) {
                return
            }

            if !force, skippedUpdateVersion == latest {
                return
            }

            await MainActor.run {
                latestVersion = latest
                showUpdateAlert = true
            }
        } catch {
            return
        }
    }

    private func isVersion(_ latest: String, greaterThan current: String) -> Bool {
        let latestParts = latest.split(separator: ".").map { Int($0) ?? 0 }
        let currentParts = current.split(separator: ".").map { Int($0) ?? 0 }
        let maxCount = max(latestParts.count, currentParts.count)

        for index in 0..<maxCount {
            let latestValue = index < latestParts.count ? latestParts[index] : 0
            let currentValue = index < currentParts.count ? currentParts[index] : 0
            if latestValue != currentValue {
                return latestValue > currentValue
            }
        }
        return false
    }
    
// Fredrik Jerdal 2025
    @MainActor
    private func clearAppData() {
        // 1) Remove API keys from both Keychain and cache
        KeychainHelper.shared.deleteAllAPIKeys()
        AgentCache.shared.clear()

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
        UserDefaults.standard.removeObject(forKey: "hideSensitive")

        // 4) Verify everything is gone
        let userDefaultsCleared =
            UserDefaults.standard.object(forKey: "hasLaunchedBefore") == nil &&
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
        if DemoMode.isEnabled || settings.baseURL.isDemoEntry {
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
                    if let body = String(data: data, encoding: .utf8),
                       body.localizedCaseInsensitiveContains("<!doctype html") ||
                       body.localizedCaseInsensitiveContains("<div id=q-app") ||
                       body.localizedCaseInsensitiveContains("<title>Tactical RMM</title>") {
                        errorMessage = nil
                        isLoading = false
                        showApiEndpointAlert = true
                        DiagnosticLogger.shared.appendWarning("Detected HTML response from /agents/. Expected API endpoint.")
                        return
                    }
                    do {
                        let decodeTask = Task<(agents: [Agent], reportedCount: Int?, usedWrapper: Bool), Error>.detached(priority: .userInitiated) {
                            let decoder = JSONDecoder()
                            if let page = try? decoder.decode(AgentListResponse.self, from: data) {
                                return (page.results, page.count, true)
                            }
                            let legacy = try decoder.decode([Agent].self, from: data)
                            return (legacy, nil, false)
                        }

                        let result = try await decodeTask.value
                        withAnimation(.easeInOut(duration: 0.25)) {
                            agents = result.agents
                        }
                        updateDisplayedAgents()
                        AgentCache.shared.setAgents(result.agents)

                        if result.usedWrapper {
                            let reportedCountLabel = result.reportedCount.map { String($0) } ?? "unknown"
                            DiagnosticLogger.shared.append("Fetched agents via wrapper: \(agents.count) (reported count: \(reportedCountLabel))")
                        } else {
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
                    if let detail = decodeAPIErrorDetail(from: data), detail == "User inactive or deleted." {
                        errorMessage = "This user account is disabled."
                        DiagnosticLogger.shared.appendError("HTTP 401 during fetch: user inactive or deleted.")
                    } else {
                        errorMessage = "Invalid API Key."
                        DiagnosticLogger.shared.appendError("HTTP 401 during fetch: invalid credentials.")
                    }
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

    private func decodeAPIErrorDetail(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let decoded = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
            return decoded.detail
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let detail = object["detail"] as? String {
            return detail
        }
        return nil
    }

    private struct APIErrorResponse: Decodable {
        let detail: String
    }

    private func loadDemoAgents() {
        DiagnosticLogger.shared.append("Loading demo agents.")
        let now = Date().timeIntervalSince1970
        withAnimation(.easeInOut(duration: 0.25)) {
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
        updateDisplayedAgents()
        AgentCache.shared.setAgents(agents)
    }
}






// MARK: - InstallAgentView

struct InstallAgentView: View {
    let baseURL: String
    let apiKey: String
    @Environment(\.appTheme) private var appTheme

    @State private var clients: [ClientModel] = []
    @State private var selectedClientId: Int?
    @State private var sites: [Site] = []
    @State private var selectedSiteId: Int?
    @State private var platform: InstallPlatform = .windows
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
    @State private var isLoadingCodeSign = false
    @State private var errorMessage: String?
    @State private var isGenerating = false
    @State private var installerURL: URL?
    @State private var showShareSheet = false
    @State private var macCommand: String?
    @State private var macDownloadURL: String?
    @State private var showCommandCopied = false
    @State private var codesignHasToken = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case expires
        case fileName
    }

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
        .navigationTitle("Install Agent")
        .task { await fetchInitialData() }
        .sheet(isPresented: $showShareSheet) {
            if platform.responseType == .file, let url = installerURL {
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
        .onChange(of: platform) { oldValue, newValue in
            handlePlatformChange(from: oldValue, to: newValue)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    focusedField = nil
                    UIApplication.shared.dismissKeyboard()
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                }
                .tint(appTheme.accent)
            }
        }
    }

    func fetchInitialData() async {
        await fetchCodeSignStatus()
        await fetchClients()
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
        installerURL = nil
        macCommand = nil
        macDownloadURL = nil
        showShareSheet = false
        showCommandCopied = false
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
            "installMethod": platform.installMethod,
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
            "plat": platform.apiPlatformValue
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
            switch platform.responseType {
            case .file:
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                try data.write(to: tempURL)
                installerURL = tempURL
                showShareSheet = true
            case .command:
                do {
                    let decoded = try JSONDecoder().decode(InstallCommandResponse.self, from: data)
                    macCommand = decoded.cmd.trimmingCharacters(in: .whitespacesAndNewlines)
                    macDownloadURL = decoded.url?.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    if let fallback = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let rawCmd = fallback["cmd"] as? String
                        let rawURL = fallback["url"] as? String
                        macCommand = rawCmd?.trimmingCharacters(in: .whitespacesAndNewlines)
                        macDownloadURL = rawURL?.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if macCommand == nil {
                        DiagnosticLogger.shared.appendError("Error decoding installer command: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            DiagnosticLogger.shared.appendError("Error generating installer: \(error.localizedDescription)")
        }
        isGenerating = false
    }

    func fetchCodeSignStatus() async {
        isLoadingCodeSign = true
        let sanitized = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitized)/core/codesign/") else {
            isLoadingCodeSign = false
            codesignHasToken = false
            ensurePlatformAvailability()
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addDefaultHeaders(apiKey: KeychainHelper.shared.getAPIKey() ?? apiKey)
        DiagnosticLogger.shared.logHTTPRequest(method: "GET", url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:])
        var hasToken = false
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let resp = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(method: "GET", url: url.absoluteString, status: resp.statusCode, data: data)
                guard resp.statusCode == 200 else {
                    isLoadingCodeSign = false
                    codesignHasToken = false
                    ensurePlatformAvailability()
                    return
                }
            }
            if let decoded = try? JSONDecoder().decode(CodeSignResponse.self, from: data) {
                hasToken = decoded.token?.isEmpty == false
            } else if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let token = object["token"] as? String, !token.isEmpty {
                    hasToken = true
                }
            }
        } catch {
            DiagnosticLogger.shared.appendError("Error fetching code sign status: \(error.localizedDescription)")
        }
        codesignHasToken = hasToken
        ensurePlatformAvailability()
        isLoadingCodeSign = false
    }

    private var destinationCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(L10n.key("installer.destination.title"), subtitle: destinationSubtitle, systemImage: "building.2")

                if let errorMessage {
                    statusBanner(message: errorMessage, isError: true)
                }

                if clients.isEmpty && !isLoadingClients && errorMessage == nil {
                    Text("No clients available. Verify your permissions or refresh.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                }

                selectionMenu(title: L10n.key("installer.destination.client"), value: selectedClientName, placeholder: L10n.key("installer.destination.selectClient"), disabled: clients.isEmpty) {
                    Button("Clear Selection", role: .destructive) {
                        selectedClientId = nil
                    }
                    ForEach(clients) { client in
                        Button(client.name) {
                            selectedClientId = client.id
                        }
                    }
                }

                selectionMenu(title: L10n.key("installer.destination.site"), value: selectedSiteName, placeholder: L10n.key("installer.destination.selectSite"), disabled: sites.isEmpty) {
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
                SectionHeader(L10n.key("installer.settings.title"), subtitle: L10n.key("installer.settings.subtitle"), systemImage: "slider.horizontal.3")

                VStack(alignment: .leading, spacing: 14) {
                    Text("Platform")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                    Picker("Platform", selection: $platform) {
                        ForEach(platformChoices, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    if isLoadingCodeSign {
                        Text("Checking signing token…")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.55))
                    } else if !codesignHasToken {
                        Text("Linux and macOS installers require a configured signing token.")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.key("agents.type.title"))
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                    Picker(L10n.key("agents.type.title"), selection: $agentType) {
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
                        ForEach(platform.architectureOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if platform.supportsRemoteOptions {
                    VStack(spacing: 12) {
                        toggleRow(title: L10n.key("installer.settings.disableSleepHibernate"), isOn: $power, disabled: agentType == "server")
                        toggleRow(title: L10n.key("Enable RDP"), isOn: $rdp)
                        toggleRow(title: L10n.key("Enable Ping"), isOn: $ping)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Expires (hours)")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                    TextField("24", text: $expires)
                        .platformKeyboardType(.numberPad)
                        .focused($focusedField, equals: .expires)
                        .submitLabel(.done)
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
                SectionHeader("Generate Installer", subtitle: L10n.key("installer.download.subtitle"), systemImage: "square.and.arrow.down")

                if platform.responseType == .file, let installerURL {
                    Text(L10n.format("Installer ready: %@", installerURL.lastPathComponent))
                        .font(.footnote)
                        .foregroundStyle(Color.green)
                        .textSelection(.enabled)
                }

                if platform.responseType == .command, let command = macCommand {
                    Text("Command ready. Copy and run on the target Mac.")
                        .font(.footnote)
                        .foregroundStyle(Color.green)

                    ScrollView {
                        Text(command)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Color.white)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                    }
                    .frame(maxHeight: 180)

                    if let urlString = macDownloadURL, !urlString.isEmpty {
                        Text(L10n.format("Package URL: %@", urlString))
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.65))
                            .textSelection(.enabled)
                    }

                    Button {
                        copyCommandToClipboard(command)
                    } label: {
                        Label("Copy Command", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .secondaryButton()

                    if showCommandCopied {
                        Text("Command copied to clipboard.")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                }

                if generateDisabled {
                    Text("Select a client and site to enable the download button.")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                }

                Button {
                    Task { await generateInstaller() }
                } label: {
                    Label(platform.downloadButtonLabel, systemImage: platform.buttonSystemImage)
                        .frame(maxWidth: .infinity)
                }
                .primaryButton()
                .disabled(generateDisabled)
                .opacity(generateDisabled ? 0.5 : 1)

                Text(platform.footerNote)
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        }
    }

    private var generateDisabled: Bool {
        isGenerating || selectedClientId == nil || selectedSiteId == nil
    }

    private var platformChoices: [InstallPlatform] {
        codesignHasToken ? InstallPlatform.allCases : [.windows]
    }

    private var destinationSubtitle: String {
        if isLoadingClients { return L10n.key("installer.destination.loading") }
        if let client = selectedClientName.nonEmpty, let site = selectedSiteName.nonEmpty {
            return "\(client) • \(site)"
        }
        return L10n.key("installer.destination.choose")
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

    private func handlePlatformChange(from _: InstallPlatform, to newValue: InstallPlatform) {
        let options = newValue.architectureOptions
        if options.contains(where: { $0.value == arch }) == false {
            arch = options.first?.value ?? arch
        }
        fileName = newValue.defaultFileName
        if newValue.supportsRemoteOptions == false {
            power = false
            rdp = false
            ping = false
        }
        installerURL = nil
        macCommand = nil
        macDownloadURL = nil
        showShareSheet = false
        showCommandCopied = false
    }

    private func ensurePlatformAvailability() {
        if platformChoices.contains(platform) == false {
            platform = .windows
        }
    }

    private func copyCommandToClipboard(_ command: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = command
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        #endif
        showCommandCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCommandCopied = false
        }
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
        .toggleStyle(SwitchToggleStyle(tint: appTheme.accent))
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


private enum InstallPlatform: String, CaseIterable {
    struct ArchitectureOption: Hashable {
        let label: String
        let value: String
    }

    enum ResponseType {
        case file
        case command
    }

    case windows
    case linux
    case mac

    var title: String {
        switch self {
        case .windows: return "Windows"
        case .linux: return "Linux"
        case .mac: return "macOS"
        }
    }

    var installMethod: String {
        switch self {
        case .windows: return "exe"
        case .linux: return "bash"
        case .mac: return "mac"
        }
    }

    var defaultFileName: String {
        switch self {
        case .windows: return "trmm-installer.exe"
        case .linux: return "trmm-installer.sh"
        case .mac: return "trmm-installer-macos.sh"
        }
    }

    var downloadButtonLabel: String {
        switch self {
        case .windows: return L10n.key("installer.download.windows")
        case .linux: return L10n.key("installer.download.linux")
        case .mac: return L10n.key("installer.download.mac")
        }
    }

    var buttonSystemImage: String {
        switch self {
        case .windows: return "icloud.and.arrow.down"
        case .linux: return "icloud.and.arrow.down"
        case .mac: return "terminal"
        }
    }

    var apiPlatformValue: String {
        switch self {
        case .windows: return "windows"
        case .linux: return "linux"
        case .mac: return "darwin"
        }
    }

    var footerNote: String {
        switch self {
        case .windows, .linux:
            return L10n.key("installer.download.expiry")
        case .mac:
            return L10n.key("installer.download.expiryMac")
        }
    }

    var architectureOptions: [ArchitectureOption] {
        switch self {
        case .windows:
            return [
                ArchitectureOption(label: "64 bit", value: "amd64"),
                ArchitectureOption(label: "32 bit", value: "386")
            ]
        case .linux:
            return [
                ArchitectureOption(label: "64 bit", value: "amd64"),
                ArchitectureOption(label: "32 bit", value: "386"),
                ArchitectureOption(label: "ARM 64 bit", value: "arm64"),
                ArchitectureOption(label: "ARM 32 bit", value: "arm")
            ]
        case .mac:
            return [
                ArchitectureOption(label: "Intel", value: "amd64"),
                ArchitectureOption(label: "Apple silicon", value: "arm64")
            ]
        }
    }

    var supportsRemoteOptions: Bool {
        switch self {
        case .windows: return true
        case .linux, .mac: return false
        }
    }

    var responseType: ResponseType {
        switch self {
        case .windows, .linux: return .file
        case .mac: return .command
        }
    }
}

private struct InstallCommandResponse: Decodable {
    let cmd: String
    let url: String?
}

private struct CodeSignResponse: Decodable {
    let token: String?
}

// MARK: - AgentDetailView

struct AgentDetailView: View {
    let agent: Agent
    let baseURL: String
    let apiKey: String
    @Environment(\.appTheme) private var appTheme
    @AppStorage("lastSeenDateFormat") private var lastSeenDateFormat: String = ""
    
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
        DemoMode.isEnabled || (baseURL.isDemoEntry && effectiveAPIKey.lowercased() == "demo")
    }
    
    @MainActor
    func fetchAgentDetail() async {
        if isDemoMode {
            DiagnosticLogger.shared.append("Demo mode active, skipping fetchAgentDetail.")
            updatedAgent = agent
            return
        }
        if ApiErrorSimulation.isEnabled {
            message = L10n.format("agents.error.http", 401)
            return
        }
        DiagnosticLogger.shared.append("AgentDetailView: fetchAgentDetail started")
        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/\(agent.agent_id)/") else {
            message = L10n.key("agents.error.invalidUrlDetails")
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
                    message = L10n.format("agents.error.http", httpResponse.statusCode)
                    DiagnosticLogger.shared.appendError("HTTP Error \(httpResponse.statusCode) during agent detail fetch.")
                    return
                }
            }
            let decodedAgent = try JSONDecoder().decode(Agent.self, from: data)
            updatedAgent = decodedAgent
            DiagnosticLogger.shared.append("Fetched updated details for agent.")
        } catch {
            message = L10n.format("agents.error.fetchDetails", error.localizedDescription)
            DiagnosticLogger.shared.appendError("Error fetching agent details: \(error.localizedDescription)")
        }
    }
    
    @MainActor
    func performWakeOnLan() async {
        if isDemoMode {
            isProcessing = true
            message = L10n.format("agents.wol.sentToFormat", agent.hostname)
            DiagnosticLogger.shared.append("Demo mode: simulated Wake-on-LAN.")
            isProcessing = false
            return
        }
        if ApiErrorSimulation.isEnabled {
            message = L10n.format("agents.error.http", 401)
            return
        }
        isProcessing = true
        message = nil
        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/\(agent.agent_id)/wol/") else {
            message = L10n.key("agents.error.invalidUrl")
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
                        if cleaned.isEmpty {
                            message = L10n.key("agents.wol.success")
                        } else if cleaned.lowercased().hasPrefix("wake-on-lan sent to ") {
                            let agentName = String(cleaned.dropFirst("Wake-on-LAN sent to ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                            let name = agentName.isEmpty ? agent.hostname : agentName
                            message = L10n.format("agents.wol.sentToFormat", name)
                        } else {
                            message = cleaned
                        }
                    } else {
                        message = L10n.key("agents.wol.success")
                    }
                } else {
                    message = L10n.format("agents.error.http", httpResponse.statusCode)
                }
            } else {
                message = L10n.key("agents.error.unknown")
            }
        } catch {
            message = L10n.format("agents.error.generic", error.localizedDescription)
            DiagnosticLogger.shared.appendError("Error in Wake‑On‑Lan: \(error.localizedDescription)")
        }
        isProcessing = false
    }
    
    @MainActor
    func performAction(action: String) async {
        let actionLabel: String = {
            switch action.lowercased() {
            case "reboot":
                return L10n.key("agents.power.reboot")
            case "shutdown":
                return L10n.key("agents.power.shutdown")
            default:
                return action.capitalized
            }
        }()

        if isDemoMode {
            message = L10n.format("agents.action.successFormat", actionLabel)
            DiagnosticLogger.shared.append("Demo mode: simulated \(action) command.")
            return
        }
        if ApiErrorSimulation.isEnabled {
            message = L10n.format("agents.error.http", 401)
            return
        }
        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/\(agent.agent_id)/\(action)/") else {
            message = L10n.key("agents.error.invalidUrl")
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
                    message = L10n.format("agents.action.successFormat", actionLabel)
                    DiagnosticLogger.shared.append("API returned \(httpResponse.statusCode), \(action) command confirmed by API.")
                } else if httpResponse.statusCode == 400 {
                    message = L10n.key("agents.action.http400Offline")
                    DiagnosticLogger.shared.appendWarning("HTTP 400 encountered during \(action) command.")
                } else {
                    message = L10n.format("agents.error.http", httpResponse.statusCode)
                    DiagnosticLogger.shared.appendError("HTTP Error \(httpResponse.statusCode) during \(action) command.")
                }
            } else {
                message = L10n.key("agents.error.unknown")
                DiagnosticLogger.shared.appendError("Unknown error during \(action) command.")
            }
        } catch {
            message = L10n.format("agents.error.generic", error.localizedDescription)
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

        func unitLabel(count: Int, singularKey: String, pluralKey: String) -> String {
            count == 1
                ? L10n.format(singularKey, count)
                : L10n.format(pluralKey, count)
        }

        var parts: [String] = []
        if months > 0 {
            parts.append(unitLabel(count: months, singularKey: "agents.uptime.month.single", pluralKey: "agents.uptime.month.plural"))
        }
        if days > 0 {
            parts.append(unitLabel(count: days, singularKey: "agents.uptime.day.single", pluralKey: "agents.uptime.day.plural"))
        }
        if hours > 0 {
            parts.append(unitLabel(count: hours, singularKey: "agents.uptime.hour.single", pluralKey: "agents.uptime.hour.plural"))
        }
        // always show minutes if nothing else, or if non-zero
        if minutes > 0 || parts.isEmpty {
            parts.append(unitLabel(count: minutes, singularKey: "agents.uptime.minute.single", pluralKey: "agents.uptime.minute.plural"))
        }
        return parts.joined(separator: " ")
    }

    /// Non-empty custom fields to display in AgentDetailView
    private var nonEmptyCustomFields: [AgentCustomField] {
        let fields = updatedAgent?.custom_fields ?? agent.custom_fields ?? []
        return fields.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private enum PowerActionType: String, Identifiable {
        case reboot
        case shutdown

        var id: String { rawValue }

        var title: String {
            switch self {
            case .reboot: return L10n.key("agents.power.confirmRebootTitle")
            case .shutdown: return L10n.key("agents.power.confirmShutdownTitle")
            }
        }

        var message: String {
            switch self {
            case .reboot: return L10n.key("agents.power.confirmRebootMessage")
            case .shutdown: return L10n.key("agents.power.confirmShutdownMessage")
            }
        }

        var confirmLabel: String {
            switch self {
            case .reboot: return L10n.key("agents.power.reboot")
            case .shutdown: return L10n.key("agents.power.shutdown")
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
        currentAgent.statusDisplayLabel
    }

    private var statusColor: Color {
        if currentAgent.isOnlineStatus { return Color.green }
        if currentAgent.isOfflineStatus { return Color.red }
        return Color.orange
    }

    private var lastSeenDisplay: String {
        formatLastSeenTimestamp(currentAgent.last_seen, customFormat: lastSeenDateFormat)
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

                infoRow(L10n.key("agents.info.site"), value: siteDisplay, systemImage: "building.2")
            }
        }
    }

    private var hardwareCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(L10n.key("agents.hardware.title"), subtitle: L10n.key("agents.hardware.subtitle"), systemImage: "cpu")
                infoRow(L10n.key("agents.hardware.cpu"), value: cpuDisplay, systemImage: "cpu")
                infoRow(L10n.key("agents.hardware.gpu"), value: gpuDisplay, systemImage: "display")
                infoRow(L10n.key("agents.hardware.model"), value: modelDisplay, systemImage: "macmini.fill")
                infoRow(L10n.key("agents.hardware.serial"), value: serialDisplay, systemImage: "barcode")
                infoRow(L10n.key("agents.hardware.disks"), value: disksDisplayText, systemImage: "internaldrive")
            }
        }
    }

    private var networkCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(L10n.key("agents.network.title"), subtitle: L10n.key("agents.network.subtitle"), systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                infoRow(L10n.key("agents.network.lanIp"), value: lanDisplay, systemImage: "network")
                infoRow(L10n.key("agents.network.publicIp"), value: publicDisplay, systemImage: "globe")
            }
        }
    }

    private var insightCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(L10n.key("agents.insight.title"), subtitle: L10n.key("agents.insight.subtitle"), systemImage: "clock")
                infoRow(L10n.key("agents.insight.status"), value: statusLabel, systemImage: "dot.radiowaves.left.and.right", tint: statusColor)
                infoRow(L10n.key("agents.insight.lastSeen"), value: lastSeenDisplay, systemImage: "clock.arrow.circlepath")
                infoRow(L10n.key("agents.insight.uptime"), value: uptimeDisplay, systemImage: "timer")
            }
        }
    }

    private var powerCard: some View {
        return GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(L10n.key("agents.power.sectionTitle"), subtitle: L10n.key("agents.power.sectionSubtitle"), systemImage: "bolt.fill")
                VStack(spacing: 16) {
                    HStack(spacing: 16) {
                        Button {
                            pendingPowerAction = .reboot
                        } label: {
                            AgentActionTile(
                                title: L10n.key("agents.power.reboot"),
                                subtitle: L10n.key("agents.power.rebootSubtitle"),
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
                                title: L10n.key("agents.power.shutdown"),
                                subtitle: L10n.key("agents.power.shutdownSubtitle"),
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
                            title: L10n.key("agents.power.wake"),
                            subtitle: L10n.key("agents.power.wakeSubtitle"),
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
                SectionHeader(L10n.key("agents.management.title"), subtitle: L10n.key("agents.management.subtitle"), systemImage: "rectangle.connected.to.line.below")
                LazyVGrid(columns: columns, spacing: 16) {
                    NavigationLink {
                        AgentProcessesView(
                            agentId: agent.agent_id,
                            baseURL: baseURL,
                            apiKey: effectiveAPIKey
                        )
                    } label: {
                        AgentActionTile(
                            title: L10n.key("agents.management.processes.title"),
                            subtitle: L10n.key("agents.management.processes.subtitle"),
                            systemImage: "chart.bar.doc.horizontal.fill",
                            tint: appTheme.accent
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        SendCommandView(
                            agentId: agent.agent_id,
                            baseURL: baseURL,
                            apiKey: effectiveAPIKey,
                            operatingSystem: agent.operating_system
                        )
                    } label: {
                        AgentActionTile(
                            title: L10n.key("agents.management.command.title"),
                            subtitle: L10n.key("agents.management.command.subtitle"),
                            systemImage: "terminal.fill",
                            tint: Color.purple
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        AgentSoftwareView(
                            agentId: agent.agent_id,
                            baseURL: baseURL,
                            apiKey: effectiveAPIKey,
                            operatingSystem: agent.operating_system
                        )
                    } label: {
                        AgentActionTile(
                            title: L10n.key("agents.management.software.title"),
                            subtitle: L10n.key("agents.management.software.subtitle"),
                            systemImage: "macwindow.on.rectangle",
                            tint: Color.mint
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        AgentCustomFieldsView(customFields: nonEmptyCustomFields)
                    } label: {
                        AgentActionTile(
                            title: L10n.key("agents.management.customFields.title"),
                            subtitle: L10n.key("agents.management.customFields.subtitle"),
                            systemImage: "doc.text.fill",
                            tint: Color.indigo
                        )
                    }
                    .buttonStyle(.plain)
                    .opacity(nonEmptyCustomFields.isEmpty ? 0.45 : 1.0)
                    .allowsHitTesting(!nonEmptyCustomFields.isEmpty)

                    NavigationLink {
                        AgentNotesView(
                            agentId: agent.agent_id,
                            baseURL: baseURL,
                            apiKey: effectiveAPIKey
                        )
                    } label: {
                        AgentActionTile(
                            title: L10n.key("agents.management.notes.title"),
                            subtitle: L10n.key("agents.management.notes.subtitle"),
                            systemImage: "note.text",
                            tint: Color.blue
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        AgentHistoryView(
                            agentId: agent.agent_id,
                            baseURL: baseURL,
                            apiKey: effectiveAPIKey
                        )
                    } label: {
                        AgentActionTile(
                            title: L10n.key("agents.management.history.title"),
                            subtitle: L10n.key("agents.management.history.subtitle"),
                            systemImage: "clock.arrow.circlepath",
                            tint: Color.cyan
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
                            title: L10n.key("agents.management.tasks.title"),
                            subtitle: L10n.key("agents.management.tasks.subtitle"),
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
                            title: L10n.key("agents.management.checks.title"),
                            subtitle: L10n.key("agents.management.checks.subtitle"),
                            systemImage: "waveform.path.ecg",
                            tint: Color.orange
                        )
                    }
                    .buttonStyle(.plain)

                }

                NavigationLink {
                    RunScriptView(
                        agent: agent,
                        baseURL: baseURL,
                        apiKey: effectiveAPIKey
                    )
                } label: {
                    AgentActionTile(
                        title: L10n.key("agents.management.runScript.title"),
                        subtitle: L10n.key("agents.management.runScript.subtitle"),
                        systemImage: "play.rectangle.on.rectangle.fill",
                        tint: Color.pink
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var statusPill: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
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
                .foregroundStyle(appTheme.accent)
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
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .padding(14)
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
    let operatingSystem: String
    @Environment(\.appTheme) private var appTheme
    
    @State private var command: String = ""
    @State private var selectedShell: String
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

    private var shellOptions: [ShellOption] {
        if SendCommandView.isUnixLike(operatingSystem) {
            return [ShellOption(label: "Bash", value: "/bin/bash")]
        }
        return [
            ShellOption(label: "CMD", value: "cmd"),
            ShellOption(label: "PowerShell", value: "powershell")
        ]
    }

    init(agentId: String, baseURL: String, apiKey: String, operatingSystem: String) {
        self.agentId = agentId
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.operatingSystem = operatingSystem
        _selectedShell = State(initialValue: SendCommandView.defaultShell(for: operatingSystem))
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
                ProgressView(L10n.key("agents.command.sending"))
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .navigationTitle(L10n.key("agents.command.title"))
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

    private struct ShellOption: Identifiable {
        let id: String
        let label: String
        let value: String

        init(label: String, value: String) {
            self.id = value
            self.label = label
            self.value = value
        }
    }

    private static func defaultShell(for os: String) -> String {
        isUnixLike(os) ? "/bin/bash" : "cmd"
    }

    private static func isUnixLike(_ os: String) -> Bool {
        let lower = os.lowercased()
        let keywords = [
            "linux", "ubuntu", "debian", "centos", "red hat", "rhel", "fedora", "suse", "opensuse",
            "arch", "manjaro", "gentoo", "mint", "pop!", "elementary", "zorin", "rocky", "alma",
            "unix", "bsd", "darwin", "mac", "os x"
        ]
        return keywords.contains { lower.contains($0) }
    }
    
    private var executionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(L10n.key("agents.command.execution.title"), subtitle: L10n.key("agents.command.execution.subtitle"), systemImage: "terminal")
                Picker(L10n.key("agents.command.shell"), selection: $selectedShell) {
                    ForEach(shellOptions) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(shellOptions.count == 1)

                HStack(spacing: 12) {
                    Image(systemName: "timer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appTheme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.key("agents.command.timeout.label"))
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.55))
                        TextField("30", text: $timeout)
                            .platformKeyboardType(.numberPad)
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

                Toggle(L10n.key("agents.command.runAsUser"), isOn: $runAsUser)
                    .toggleStyle(SwitchToggleStyle(tint: .cyan))

                Button {
                    UIApplication.shared.dismissKeyboard()
                    timeoutFocused = false
                    commandFocused = false
                    Task { await sendCommand() }
                } label: {
                    Label(L10n.key("agents.command.send"), systemImage: "paperplane.fill")
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
                SectionHeader(L10n.key("agents.command.editor.title"), subtitle: L10n.key("agents.command.editor.subtitle"), systemImage: "chevron.left.forwardslash.chevron.right")
                TextEditor(text: $command)
                    .focused($commandFocused)
                    .frame(minHeight: 180)
                    .padding(12)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
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
                    SectionHeader(L10n.key("agents.command.output.title"), subtitle: L10n.key("agents.command.output.subtitle"), systemImage: "terminal")
                    if text.isEmpty {
                        Text(L10n.key("agents.command.output.empty"))
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
            statusMessage = L10n.key("agents.command.error.invalidTimeout")
            return
        }

        let sanitizedCommand = trimmedCommand
        guard !sanitizedCommand.isEmpty else {
            statusMessage = L10n.key("agents.command.error.emptyCommand")
            return
        }

        command = sanitizedCommand
        isProcessing = true
        clearCommandOutput()
        statusMessage = nil

        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/\(agentId)/cmd/") else {
            statusMessage = L10n.key("common.invalidUrl")
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
            statusMessage = L10n.format("agents.command.error.prepareRequestFormat", error.localizedDescription)
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
                    statusMessage = L10n.key("agents.command.success.sent")
                } else {
                    let backendMessage = extractBackendMessage(from: data)
                    if httpResponse.statusCode == 400, let backendMessage {
                        statusMessage = backendMessage
                    } else if let backendMessage {
                        statusMessage = backendMessage
                    } else {
                        statusMessage = L10n.format("common.httpErrorFormat", httpResponse.statusCode)
                    }
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
            statusMessage = L10n.format("common.errorFormat", error.localizedDescription)
            DiagnosticLogger.shared.appendError("Error sending command: \(error.localizedDescription)")
        }

        isProcessing = false
    }
}

private extension SendCommandView {
    private func extractBackendMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if let decodedString = try? JSONDecoder().decode(String.self, from: data), let clean = decodedString.nonEmpty {
            return clean
        }

        if let jsonObject = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let dict = jsonObject as? [String: Any] {
                let preferredKeys = ["detail", "message", "error"]
                for key in preferredKeys {
                    if let value = dict[key] as? String, let clean = value.nonEmpty { return clean }
                    if let array = dict[key] as? [String], let first = array.first?.nonEmpty { return first }
                }

                for value in dict.values {
                    if let stringValue = value as? String, let clean = stringValue.nonEmpty { return clean }
                    if let array = value as? [String], let first = array.first?.nonEmpty { return first }
                }
            } else if let array = jsonObject as? [String], let first = array.first?.nonEmpty {
                return first
            }
        }

        if let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           !raw.lowercased().hasPrefix("<html") {
            return raw
        }

        return nil
    }
}

// MARK: - RunScriptView

struct RunScriptView: View {
    let agent: Agent
    let baseURL: String
    let apiKey: String
    @Environment(\.appTheme) private var appTheme
    @AppStorage("hideCommunityScripts") private var hideCommunityScripts: Bool = false

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
                    .tint(appTheme.accent)
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
        .settingsPresentation(
            isPresented: $showScriptPicker,
            fullScreen: ProcessInfo.processInfo.isiOSAppOnMac
        ) {
            ScriptPickerView(
                scripts: scripts,
                agentPlatform: normalizedAgentPlatform,
                selectedScriptID: $selectedScriptID,
                onClose: { showScriptPicker = false }
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
                SectionHeader(L10n.key("runScript.scripts.title"), subtitle: L10n.key("runScript.scripts.subtitle"), systemImage: "scroll")

                if isLoadingScripts {
                    ProgressView("Loading scripts…")
                        .tint(appTheme.accent)
                } else if let error = scriptsError {
                    Text(L10n.format("Error: %@", error))
                        .font(.footnote)
                        .foregroundStyle(Color.red)
                } else if scripts.isEmpty {
                    Text(L10n.key("No scripts available. Create scripts in Tactical RMM first."))
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else {
                    Button {
                        showScriptPicker = true
                    } label: {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(selectedScript?.name ?? L10n.key("runScript.scripts.choose"))
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
                                .foregroundStyle(appTheme.accent)
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
                SectionHeader(L10n.key("runScript.configuration.title"), subtitle: L10n.key("runScript.configuration.subtitle"), systemImage: "slider.horizontal.3")

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
                                .foregroundStyle(appTheme.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Timeout (seconds)")
                                    .font(.caption2)
                                    .foregroundStyle(Color.white.opacity(0.55))
                                TextField(String(script.defaultTimeout), text: $timeout)
                                    .platformKeyboardType(.numberPad)
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
                                        .platformKeyboardType(.emailAddress)
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
        DemoMode.isEnabled || (baseURL.isDemoEntry && effectiveAPIKey.lowercased() == "demo")
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
                    .foregroundStyle(appTheme.accent)
                Text(script.category?.nonEmpty ?? "Uncategorized")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            Text("Shell: \(script.shell.uppercased()) • Timeout: \(script.defaultTimeout)s")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.55))
            Text(L10n.format("Platforms: %@", platformsLabel(for: script)))
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.55))
        }
    }

    private func scriptMetaRow(systemImage: String, label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(appTheme.accent)
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
                    SectionHeader(L10n.key("runScript.result.title"), subtitle: L10n.key("runScript.result.subtitle"), systemImage: "doc.text")
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
        let scriptsPath = hideCommunityScripts ? "/scripts/?showCommunityScripts=false" : "/scripts/"
        guard let url = URL(string: "\(sanitized)\(scriptsPath)") else {
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
            statusMessage = L10n.format("Error: %@", error.localizedDescription)
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
        let onClose: () -> Void

        @Environment(\.dismiss) private var dismiss
        @Environment(\.appTheme) private var appTheme
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
                                .foregroundStyle(appTheme.accent)
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
                                            onClose()
                                            dismiss()
                                        }
                                    }
                                }
                            }
                        }
                        .scrollContentBackground(.hidden)
                        .listStyle(.insetGrouped)
                        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: L10n.key("scripts.search.placeholder"))
                        .background(DarkGradientBackground().ignoresSafeArea())
                        .overlay {
                            if filteredScripts.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.title2)
                                        .foregroundStyle(appTheme.accent)
                                    Text(L10n.key("No scripts match your search."))
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
                        Button("Cancel") {
                            onClose()
                            dismiss()
                        }
                    }
                }
            }
        }

        private struct ScriptRow: View {
            let script: RMMScript
            let isSelected: Bool
            let supported: Bool
            @Environment(\.appTheme) private var appTheme

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
                            .foregroundStyle(appTheme.accent)
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

    private var isDemoMode: Bool {
        DemoMode.isEnabled || (baseURL.isDemoEntry && effectiveAPIKey.lowercased() == "demo")
    }

    private static let demoProcesses: [ProcessRecord] = [
        ProcessRecord(id: 1, name: "Explorer", pid: 4240, membytes: 145_760_256, username: "SYSTEM", cpu_percent: "0.6"),
        ProcessRecord(id: 2, name: "chrome", pid: 1328, membytes: 312_500_224, username: "demo.user", cpu_percent: "3.1"),
        ProcessRecord(id: 3, name: "Code", pid: 2210, membytes: 268_435_456, username: "demo.user", cpu_percent: "1.7"),
        ProcessRecord(id: 4, name: "OneDrive", pid: 1760, membytes: 98_304_512, username: "demo.user", cpu_percent: "0.2"),
        ProcessRecord(id: 5, name: "svchost", pid: 840, membytes: 72_351_744, username: "LOCAL SERVICE", cpu_percent: "0.1")
    ]

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
                ProgressView(L10n.key("agents.processes.loading"))
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .navigationTitle(L10n.key("agents.processes.title"))
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
                SectionHeader(L10n.key("agents.processes.search.title"), subtitle: L10n.key("agents.processes.search.subtitle"), systemImage: "magnifyingglass")
                TextField(L10n.key("agents.processes.search.placeholder"), text: $searchQuery)
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
                SectionHeader(L10n.key("agents.processes.list.title"), subtitle: listSubtitle, systemImage: "memorychip")

                if processRecords.isEmpty && errorMessage == nil && !isLoading {
                    Text(L10n.key("agents.processes.empty"))
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else if displayedProcesses.isEmpty && !processRecords.isEmpty {
                    Text(L10n.key("agents.processes.emptyFiltered"))
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
                    .animation(.easeInOut(duration: 0.25), value: displayedProcesses.count)
                }

                if let killBannerMessage {
                    statusBanner(killBannerMessage, isError: killBannerMessage.lowercased().contains("fail") || killBannerMessage.lowercased().contains("error"))
                }
            }
        }
    }

    private var stickyKillBar: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(L10n.key("agents.processes.terminate.title"), subtitle: L10n.key("agents.processes.terminate.subtitle"), systemImage: "nosign")

            if let process = selectedProcess {
                Text(L10n.format("agents.processes.terminate.ready", process.name, String(process.pid)))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.85))
            } else {
                Text(L10n.key("agents.processes.terminate.prompt"))
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
            .buttonBorderShape(.roundedRectangle(radius: 14))
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
        if isLoading { return L10n.key("common.loading") }
        if !appliedSearchQuery.isEmpty { return L10n.format("agents.processes.subtitle.filteredFormat", displayedProcesses.count) }
        return L10n.format("agents.processes.subtitle.totalFormat", processRecords.count)
    }

    private var selectedProcessLabel: String {
        if let process = selectedProcess {
            return L10n.format("agents.processes.terminate.buttonSelected", process.name, String(process.pid))
        }
        return L10n.key("agents.processes.terminate.buttonPid")
    }

    private var killSheet: some View {
        NavigationView {
            ZStack {
                DarkGradientBackground()
                VStack(spacing: 24) {
                    Text(L10n.key("agents.processes.killSheet.title"))
                        .font(.headline)
                        .foregroundStyle(Color.white)
                    TextField(L10n.key("agents.processes.killSheet.pidPlaceholder"), text: $pidToKill)
                        .platformKeyboardType(.numberPad)
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
                        Button(L10n.key("common.cancel")) {
                            showKillSheet = false
                        }
                        .secondaryButton()

                        Button(L10n.key("agents.processes.killSheet.confirm"), role: .destructive) {
                            Task {
                                if let pidInt = Int(pidToKill), pidInt > 0 {
                                    await killProcess(withPid: pidInt)
                                } else {
                                    killBannerMessage = L10n.key("agents.processes.invalidPid")
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
        @Environment(\.appTheme) private var appTheme

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(process.name)
                        .font(.headline)
                    Spacer()
                    Text(L10n.format("PID %lld", process.pid))
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                Text(L10n.format("User: %@", process.username))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.7))
                HStack(spacing: 12) {
                    pill(label: "CPU \(process.cpu_percent)%", color: Color.orange)
                    pill(label: "RAM \(process.membytes)", color: appTheme.accent)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.12 : 0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(isSelected ? appTheme.accent.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1)
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
        if ApiErrorSimulation.isEnabled {
            errorMessage = L10n.format("agents.error.http", 401)
            return
        }
        if isDemoMode {
            guard fetchID == processFetchSequence else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                processRecords = Self.demoProcesses
                deletedPIDs.removeAll()
            }
            return
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
                    if httpResponse.statusCode == 400 {
                        errorMessage = L10n.key("agents.action.http400Offline")
                        DiagnosticLogger.shared.appendWarning("HTTP 400 encountered while fetching processes. Agent may be offline.")
                    } else {
                        errorMessage = "HTTP Error: \(httpResponse.statusCode)"
                        DiagnosticLogger.shared.appendError("HTTP Error \(httpResponse.statusCode) in fetching processes.")
                    }
                    return
                }
            }
            let decodedProcesses = try JSONDecoder().decode([ProcessRecord].self, from: data)
            guard fetchID == processFetchSequence else {
                DiagnosticLogger.shared.append("Discarded stale process fetch (id: \(fetchID))")
                return
            }
            withAnimation(.easeInOut(duration: 0.25)) {
                processRecords = decodedProcesses
                deletedPIDs.removeAll()
            }
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
        if isDemoMode {
            killBannerMessage = "Demo mode: process \(pid) terminated."
            selectedProcess = nil
            withAnimation(.easeInOut(duration: 0.2)) {
                processRecords.removeAll { $0.pid == pid }
                deletedPIDs.insert(pid)
            }
            pidToKill = ""
            return
        }
        if ApiErrorSimulation.isEnabled {
            killBannerMessage = L10n.format("agents.error.http", 401)
            return
        }
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
                    withAnimation(.easeInOut(duration: 0.2)) {
                        processRecords.removeAll { $0.pid == pid }
                        deletedPIDs.insert(pid)
                    }
                    pidToKill = ""
                } else if httpResponse.statusCode == 400 {
                    killBannerMessage = L10n.key("agents.action.http400Offline")
                    DiagnosticLogger.shared.appendWarning("HTTP 400 encountered while killing process \(pid). Agent may be offline.")
                } else {
                    killBannerMessage = "Failed to kill process \(pid)."
                    DiagnosticLogger.shared.appendError("Failed to kill process \(pid), HTTP status \(httpResponse.statusCode).")
                }
            }
        } catch {
            killBannerMessage = L10n.format("Error: %@", error.localizedDescription)
            DiagnosticLogger.shared.appendError("Error in kill process: \(error.localizedDescription)")
        }
    }
}

// MARK: - AgentSoftwareView

struct AgentSoftwareView: View {
    private enum InventoryMode: String, CaseIterable, Identifiable {
        case software
        case services

        var id: String { rawValue }

        var title: String {
            switch self {
            case .software:
                return L10n.key("agents.software.title")
            case .services:
                return L10n.key("agents.services.title")
            }
        }
    }

    private enum ServiceAction: String {
        case stop
        case start
        case restart

        var payloadValue: String { rawValue }

        var label: String {
            switch self {
            case .stop:
                return L10n.key("agents.services.action.stop")
            case .start:
                return L10n.key("agents.services.action.start")
            case .restart:
                return L10n.key("agents.services.action.restart")
            }
        }
    }

    private static let invalidDates: Set<String> = ["01-1-01", "0001-01-01", "1900-01-01"]

    private static let isoDateFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let installDateParsers: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd",
            "yyyy-M-d",
            "dd-MM-yyyy",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
    }()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    let agentId: String
    let baseURL: String
    let apiKey: String
    let operatingSystem: String

    @State private var selectedMode: InventoryMode = .software
    @State private var inventory: [InstalledSoftware] = []
    @State private var services: [AgentService] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var statusMessage: String? = nil
    @State private var searchQuery: String = ""
    @State private var appliedSearchQuery: String = ""
    @State private var hasLoadedSoftware: Bool = false
    @State private var hasLoadedServices: Bool = false
    @State private var uninstallingSoftwareIDs: Set<String> = []
    @State private var pendingUninstallSoftware: InstalledSoftware? = nil
    @State private var uninstallCommandText: String = ""
    @State private var uninstallTimeoutText: String = "1800"
    @State private var uninstallRunAsUser: Bool = false
    @State private var uninstallSheetError: String? = nil
    @State private var isSubmittingUninstall: Bool = false
    @State private var serviceActionInProgressIDs: Set<String> = []

    @FocusState private var searchFocused: Bool

    private var isWindowsAgent: Bool {
        isDemoMode || operatingSystem.lowercased().contains("windows")
    }

    private var isDemoMode: Bool {
        DemoMode.isEnabled || (baseURL.isDemoEntry && effectiveAPIKey.lowercased() == "demo")
    }

    private static let demoInventory: [InstalledSoftware] = [
        InstalledSoftware(
            name: "Microsoft Edge",
            size: "321 MB",
            source: "winget",
            version: "128.0.2739.42",
            location: "C:\\Program Files (x86)\\Microsoft\\Edge\\Application",
            publisher: "Microsoft Corporation",
            uninstall: "\"C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\128.0.2739.42\\Installer\\setup.exe\" --uninstall --system-level",
            install_date: "2024-08-12"
        ),
        InstalledSoftware(
            name: "7-Zip",
            size: "5 MB",
            source: "choco",
            version: "23.01",
            location: "C:\\Program Files\\7-Zip",
            publisher: "Igor Pavlov",
            uninstall: "\"C:\\Program Files\\7-Zip\\Uninstall.exe\"",
            install_date: "2024-06-03"
        ),
        InstalledSoftware(
            name: "Visual Studio Code",
            size: "412 MB",
            source: "winget",
            version: "1.92.2",
            location: "C:\\Users\\demo.user\\AppData\\Local\\Programs\\Microsoft VS Code",
            publisher: "Microsoft Corporation",
            uninstall: "\"C:\\Users\\demo.user\\AppData\\Local\\Programs\\Microsoft VS Code\\unins000.exe\" /SILENT",
            install_date: "2024-07-18"
        ),
        InstalledSoftware(
            name: "Git",
            size: "120 MB",
            source: "manual",
            version: "2.46.0",
            location: "C:\\Program Files\\Git",
            publisher: "The Git Development Community",
            uninstall: "\"C:\\Program Files\\Git\\unins000.exe\" /VERYSILENT",
            install_date: "2024-05-21"
        )
    ]

    private static let demoServices: [AgentService] = [
        AgentService(
            name: "a2AntiMalware",
            status: "running",
            display_name: "Emsisoft Protection Service",
            binpath: "\"C:\\Program Files\\Emsisoft Anti-Malware\\a2service.exe\"",
            description: "Scans the PC for unwanted software and provides protection from malicious code",
            username: "LocalSystem",
            pid: 2248,
            start_type: "Automatic",
            autodelay: false
        ),
        AgentService(
            name: "ALG",
            status: "stopped",
            display_name: "Application Layer Gateway Service",
            binpath: "C:\\WINDOWS\\System32\\alg.exe",
            description: "Provides support for 3rd party protocol plug-ins for Internet Connection Sharing",
            username: "NT AUTHORITY\\LocalService",
            pid: 0,
            start_type: "Manual",
            autodelay: false
        ),
        AgentService(
            name: "AppHostSvc",
            status: "running",
            display_name: "Application Host Helper Service",
            binpath: "C:\\WINDOWS\\system32\\svchost.exe -k apphost",
            description: "Provides administrative services for IIS, for example configuration history and Application Pool account mapping.",
            username: "LocalSystem",
            pid: 5016,
            start_type: "Automatic",
            autodelay: false
        )
    ]

    private var softwareEndpointRoot: String {
        baseURL.removingTrailingSlash() + "/software"
    }

    private var servicesEndpointRoot: String {
        baseURL.removingTrailingSlash() + "/services"
    }

    var effectiveAPIKey: String {
        KeychainHelper.shared.getAPIKey() ?? apiKey
    }

    private var filteredInventory: [InstalledSoftware] {
        guard !appliedSearchQuery.isEmpty else { return inventory }
        let needle = appliedSearchQuery
        return inventory.filter { item in
            item.name.localizedCaseInsensitiveContains(needle)
        }
    }

    private var filteredServices: [AgentService] {
        guard !appliedSearchQuery.isEmpty else { return services }
        let needle = appliedSearchQuery
        return services.filter { item in
            [item.name, item.display_name, item.description, item.binpath, item.username, item.start_type, item.status]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private var listSubtitle: String {
        if isLoading { return L10n.key("common.loading") }
        let count = selectedMode == .software ? filteredInventory.count : filteredServices.count
        let baseCount = selectedMode == .software ? inventory.count : services.count
        if !appliedSearchQuery.isEmpty {
            return count == 1 ? "1 match" : "\(count) matches"
        }
        return baseCount == 1
            ? L10n.format("agents.inventory.count.single", baseCount)
            : L10n.format("agents.inventory.count.multipleFormat", baseCount)
    }

    private var loadingLabel: String {
        selectedMode == .software ? L10n.key("agents.software.loading") : L10n.key("agents.services.loading")
    }

    private var filterSectionTitle: String {
        selectedMode == .software
            ? L10n.key("agents.software.filter.title")
            : L10n.key("agents.services.filter.title")
    }

    private var filterSectionSubtitle: String {
        selectedMode == .software
            ? L10n.key("agents.software.filter.subtitle")
            : L10n.key("agents.services.filter.subtitle")
    }

    var body: some View {
        ZStack {
            DarkGradientBackground()

            if isWindowsAgent {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        searchCard
                        inventoryListCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .padding(.bottom, 180)
                }
                .refreshable {
                    await fetchCurrentInventory(force: true)
                }

                if isLoading {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                    ProgressView(loadingLabel)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }
            } else {
                unsupportedView
            }
        }
        .navigationTitle(L10n.key("agents.software.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard isWindowsAgent else { return }
            Task { await fetchCurrentInventory() }
        }
        .onChange(of: selectedMode) { _, _ in
            appliedSearchQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { await fetchCurrentInventory(force: true) }
        }
        .sheet(isPresented: Binding(
            get: { pendingUninstallSoftware != nil },
            set: { value in
                if !value {
                    pendingUninstallSoftware = nil
                    uninstallSheetError = nil
                    isSubmittingUninstall = false
                }
            }
        )) {
            if let software = pendingUninstallSoftware {
                UninstallSoftwareSheet(
                    software: software,
                    command: $uninstallCommandText,
                    timeout: $uninstallTimeoutText,
                    runAsUser: $uninstallRunAsUser,
                    isSubmitting: isSubmittingUninstall,
                    errorMessage: uninstallSheetError,
                    onCancel: {
                        pendingUninstallSoftware = nil
                        uninstallSheetError = nil
                        isSubmittingUninstall = false
                    },
                    onConfirm: {
                        Task { await submitUninstall() }
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            } else {
                EmptyView()
            }
        }
        .keyboardDismissToolbar()
    }

    @MainActor
    private func presentUninstallSheet(for software: InstalledSoftware) {
        guard let preset = software.uninstall.nonEmpty else {
            errorMessage = L10n.format("agents.software.uninstall.unavailableFormat", software.name)
            statusMessage = nil
            return
        }
        pendingUninstallSoftware = software
        uninstallCommandText = preset
        uninstallTimeoutText = "1800"
        uninstallRunAsUser = false
        uninstallSheetError = nil
        isSubmittingUninstall = false
    }

    private var searchCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                Picker(L10n.key("agents.inventory.picker.title"), selection: $selectedMode) {
                    ForEach(InventoryMode.allCases) { mode in
                        Text(mode.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .multilineTextAlignment(.center)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                SectionHeader(filterSectionTitle, subtitle: filterSectionSubtitle, systemImage: "magnifyingglass")
                TextField(selectedMode == .software ? L10n.key("agents.software.filter.placeholder") : L10n.key("agents.services.filter.placeholder"), text: $searchQuery)
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
                    .onSubmit {
                        appliedSearchQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    .onChange(of: searchQuery) { _, newValue in
                        appliedSearchQuery = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    }

                if let errorMessage {
                    banner(errorMessage, isError: true)
                }
                if let statusMessage {
                    banner(statusMessage, isError: false)
                }
            }
        }
    }

    private var inventoryListCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(selectedMode == .software ? L10n.key("agents.software.title") : L10n.key("agents.services.title"), subtitle: listSubtitle, systemImage: selectedMode == .software ? "macwindow" : "gearshape.2")

                if selectedMode == .software && inventory.isEmpty && !isLoading && errorMessage == nil {
                    Text(L10n.key("agents.software.empty"))
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else if selectedMode == .services && services.isEmpty && !isLoading && errorMessage == nil {
                    Text(L10n.key("agents.services.empty"))
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else if selectedMode == .software && filteredInventory.isEmpty && !inventory.isEmpty {
                    Text(L10n.key("agents.software.emptyFiltered"))
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else if selectedMode == .services && filteredServices.isEmpty && !services.isEmpty {
                    Text(L10n.key("agents.services.emptyFiltered"))
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else {
                    LazyVStack(spacing: 14) {
                        if selectedMode == .software {
                            ForEach(filteredInventory) { item in
                                SoftwareTile(
                                    software: item,
                                    installDate: formattedInstallDate(item.install_date),
                                    isUninstalling: uninstallingSoftwareIDs.contains(item.id),
                                    onRequestUninstall: { selected in
                                        presentUninstallSheet(for: selected)
                                    }
                                )
                            }
                        } else {
                            ForEach(filteredServices) { item in
                                ServiceTile(
                                    service: item,
                                    isActionInProgress: serviceActionInProgressIDs.contains(item.id),
                                    onAction: { service, action in
                                        Task { await sendServiceAction(service, action: action) }
                                    }
                                )
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: selectedMode == .software ? filteredInventory.count : filteredServices.count)
                }
            }
        }
    }

    @MainActor
    private func submitUninstall() async {
        guard let software = pendingUninstallSoftware else { return }

        if isDemoMode {
            pendingUninstallSoftware = nil
            statusMessage = "Demo mode: uninstall queued for \(software.name)."
            uninstallCommandText = ""
            uninstallTimeoutText = "1800"
            uninstallRunAsUser = false
            return
        }
        if ApiErrorSimulation.isEnabled {
            uninstallSheetError = "HTTP Error: 401"
            return
        }

        let trimmedCommand = uninstallCommandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            uninstallSheetError = L10n.key("agents.software.uninstall.commandRequired")
            return
        }

        let trimmedTimeoutText = uninstallTimeoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let timeout = Int(trimmedTimeoutText), timeout > 0 else {
            uninstallSheetError = L10n.key("agents.software.uninstall.timeoutPositive")
            return
        }

        let trimmedAgent = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAgent.isEmpty else {
            uninstallSheetError = L10n.key("agents.software.uninstall.missingAgent")
            return
        }

        let token = effectiveAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            uninstallSheetError = L10n.key("agents.software.uninstall.missingApiKey")
            return
        }

        guard let url = URL(string: "\(softwareEndpointRoot)/\(trimmedAgent)/uninstall/") else {
            uninstallSheetError = "Invalid uninstall endpoint."
            DiagnosticLogger.shared.appendError("Invalid uninstall URL constructed for agent \(trimmedAgent).")
            return
        }

        isSubmittingUninstall = true
        uninstallSheetError = nil
        statusMessage = nil
        uninstallingSoftwareIDs.insert(software.id)
        defer {
            isSubmittingUninstall = false
            uninstallingSoftwareIDs.remove(software.id)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.addDefaultHeaders(apiKey: token)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "name": software.name,
            "command": trimmedCommand,
            "run_as_user": uninstallRunAsUser,
            "timeout": timeout
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            uninstallSheetError = "Failed to encode request."
            DiagnosticLogger.shared.appendError("Failed to encode uninstall payload: \(error.localizedDescription)")
            isSubmittingUninstall = false
            uninstallingSoftwareIDs.remove(software.id)
            return
        }

        DiagnosticLogger.shared.logHTTPRequest(method: "POST", url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:])
        if let body = request.httpBody, let bodyString = String(data: body, encoding: .utf8) {
            DiagnosticLogger.shared.append("Body: \(bodyString)")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(method: "POST", url: url.absoluteString, status: http.statusCode, data: data)
                guard (200...299).contains(http.statusCode) else {
                    uninstallSheetError = "HTTP Error: \(http.statusCode)"
                    DiagnosticLogger.shared.appendError("HTTP Error \(http.statusCode) when submitting uninstall for \(software.name).")
                    return
                }
            }

            pendingUninstallSoftware = nil
            statusMessage = "Uninstall command sent for \(software.name)."
            uninstallCommandText = ""
            uninstallTimeoutText = "1800"
            uninstallRunAsUser = false
            await fetchSoftwareInventory(force: true)
        } catch {
            uninstallSheetError = error.localizedDescription
            DiagnosticLogger.shared.appendError("Error submitting uninstall: \(error.localizedDescription)")
        }

    }

    private func banner(_ message: String, isError: Bool) -> some View {
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

    private func formattedInstallDate(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if Self.invalidDates.contains(trimmed) { return nil }

        if let date = Self.isoDateFormatterWithFractional.date(from: trimmed)
            ?? Self.isoDateFormatter.date(from: trimmed) {
            return Self.displayDateFormatter.string(from: date)
        }

        for parser in Self.installDateParsers {
            if let date = parser.date(from: trimmed) {
                return Self.displayDateFormatter.string(from: date)
            }
        }

        return trimmed
    }

    @MainActor
    private func fetchCurrentInventory(force: Bool = false) async {
        switch selectedMode {
        case .software:
            if hasLoadedSoftware && !force { return }
            await fetchSoftwareInventory(force: force)
            hasLoadedSoftware = true
        case .services:
            if hasLoadedServices && !force { return }
            await fetchServicesInventory(force: force)
            hasLoadedServices = true
        }
    }

    @MainActor
    func fetchSoftwareInventory(force: Bool = false) async {
        guard isWindowsAgent else { return }
        if isLoading && !force { return }

        if isDemoMode {
            isLoading = true
            errorMessage = nil
            statusMessage = nil
            withAnimation(.easeInOut(duration: 0.25)) {
                inventory = Self.demoInventory
            }
            hasLoadedSoftware = true
            isLoading = false
            return
        }
        if ApiErrorSimulation.isEnabled {
            isLoading = true
            errorMessage = "HTTP Error: 401"
            statusMessage = nil
            isLoading = false
            return
        }

        let trimmedAgent = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAgent.isEmpty else {
            errorMessage = "Missing agent identifier."
            return
        }

        let token = effectiveAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorMessage = "Add an API key in Settings before fetching software."
            return
        }

        guard let url = URL(string: "\(softwareEndpointRoot)/\(trimmedAgent)/") else {
            errorMessage = "Invalid endpoint."
            DiagnosticLogger.shared.appendError("Invalid software inventory URL constructed for agent \(trimmedAgent).")
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        request.addDefaultHeaders(apiKey: token)

        DiagnosticLogger.shared.logHTTPRequest(
            method: "GET",
            url: url.absoluteString,
            headers: request.allHTTPHeaderFields ?? [:]
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(method: "GET", url: url.absoluteString, status: http.statusCode, data: data)
                guard (200...299).contains(http.statusCode) else {
                    errorMessage = "HTTP Error: \(http.statusCode)"
                    DiagnosticLogger.shared.appendError("HTTP Error \(http.statusCode) when fetching software inventory for agent \(trimmedAgent).")
                    return
                }
            }

            let sortedInventory = try await Task<[InstalledSoftware], Error>.detached(priority: .userInitiated) {
                let decoder = JSONDecoder()
                if let wrapped = try? decoder.decode(SoftwareInventoryResponse.self, from: data) {
                    return wrapped.software.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                }
                let items = try decoder.decode([InstalledSoftware].self, from: data)
                return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }.value

            withAnimation(.easeInOut(duration: 0.25)) {
                inventory = sortedInventory
            }
            hasLoadedSoftware = true
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Error fetching software inventory: \(error.localizedDescription)")
        }
    }

    @MainActor
    func fetchServicesInventory(force: Bool = false) async {
        guard isWindowsAgent else { return }
        if isLoading && !force { return }

        if isDemoMode {
            isLoading = true
            errorMessage = nil
            statusMessage = nil
            withAnimation(.easeInOut(duration: 0.25)) {
                services = Self.demoServices
            }
            hasLoadedServices = true
            isLoading = false
            return
        }
        if ApiErrorSimulation.isEnabled {
            isLoading = true
            errorMessage = "HTTP Error: 401"
            statusMessage = nil
            isLoading = false
            return
        }

        let trimmedAgent = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAgent.isEmpty else {
            errorMessage = "Missing agent identifier."
            return
        }

        let token = effectiveAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorMessage = "Add an API key in Settings before fetching services."
            return
        }

        guard let url = URL(string: "\(servicesEndpointRoot)/\(trimmedAgent)") else {
            errorMessage = "Invalid endpoint."
            DiagnosticLogger.shared.appendError("Invalid services URL constructed for agent \(trimmedAgent).")
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 45
        request.addDefaultHeaders(apiKey: token)

        DiagnosticLogger.shared.logHTTPRequest(
            method: "GET",
            url: url.absoluteString,
            headers: request.allHTTPHeaderFields ?? [:]
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(method: "GET", url: url.absoluteString, status: http.statusCode, data: data)
                guard (200...299).contains(http.statusCode) else {
                    errorMessage = http.statusCode == 400 ? L10n.key("agents.services.unableToContactAgent") : "HTTP Error: \(http.statusCode)"
                    DiagnosticLogger.shared.appendError("HTTP Error \(http.statusCode) when fetching services for agent \(trimmedAgent).")
                    return
                }
            }

            let sortedServices = try await Task<[AgentService], Error>.detached(priority: .userInitiated) {
                let decoder = JSONDecoder()
                if let wrapped = try? decoder.decode(ServiceInventoryResponse.self, from: data) {
                    return wrapped.services.sorted { $0.display_name.localizedCaseInsensitiveCompare($1.display_name) == .orderedAscending }
                }
                let items = try decoder.decode([AgentService].self, from: data)
                return items.sorted { $0.display_name.localizedCaseInsensitiveCompare($1.display_name) == .orderedAscending }
            }.value

            withAnimation(.easeInOut(duration: 0.25)) {
                services = sortedServices
            }
            hasLoadedServices = true
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                return
            }
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Error fetching services: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func sendServiceAction(_ service: AgentService, action: ServiceAction) async {
        if serviceActionInProgressIDs.contains(service.id) {
            return
        }

        if isDemoMode {
            errorMessage = nil
            return
        }

        if ApiErrorSimulation.isEnabled {
            errorMessage = "HTTP Error: 401"
            statusMessage = nil
            return
        }

        let trimmedAgent = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAgent.isEmpty else {
            errorMessage = "Missing agent identifier."
            statusMessage = nil
            return
        }

        let token = effectiveAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            errorMessage = "Add an API key in Settings before managing services."
            statusMessage = nil
            return
        }

        let pathAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let encodedServiceName = service.name.addingPercentEncoding(withAllowedCharacters: pathAllowed),
              !encodedServiceName.isEmpty,
              let url = URL(string: "\(servicesEndpointRoot)/\(trimmedAgent)/\(encodedServiceName)/") else {
            errorMessage = "Invalid service endpoint."
            statusMessage = nil
            DiagnosticLogger.shared.appendError("Invalid service action URL for service \(service.name) and agent \(trimmedAgent).")
            return
        }

        serviceActionInProgressIDs.insert(service.id)
        var shouldClearPendingOnExit = true
        defer {
            if shouldClearPendingOnExit {
                serviceActionInProgressIDs.remove(service.id)
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.addDefaultHeaders(apiKey: token)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "sv_action": action.payloadValue
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            errorMessage = "Failed to encode request."
            statusMessage = nil
            DiagnosticLogger.shared.appendError("Failed to encode service action payload: \(error.localizedDescription)")
            return
        }

        DiagnosticLogger.shared.logHTTPRequest(method: "POST", url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:])
        if let body = request.httpBody, let bodyString = String(data: body, encoding: .utf8) {
            DiagnosticLogger.shared.append("Body: \(bodyString)")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(method: "POST", url: url.absoluteString, status: http.statusCode, data: data)
                guard (200...299).contains(http.statusCode) else {
                    errorMessage = http.statusCode == 400 ? L10n.key("agents.services.unableToContactAgent") : "HTTP Error: \(http.statusCode)"
                    statusMessage = nil
                    DiagnosticLogger.shared.appendError("HTTP Error \(http.statusCode) when running \(action.payloadValue) for service \(service.name).")
                    return
                }
            }

            serviceActionInProgressIDs.remove(service.id)
            shouldClearPendingOnExit = false

            errorMessage = nil
            await fetchServicesInventory(force: true)

            if serviceHasPendingStatus(named: service.name) {
                for _ in 0..<8 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await fetchServicesInventory(force: true)
                    if !serviceHasPendingStatus(named: service.name) {
                        break
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
            DiagnosticLogger.shared.appendError("Error sending service action: \(error.localizedDescription)")
        }
    }

    private func serviceHasPendingStatus(named serviceName: String) -> Bool {
        guard let service = services.first(where: { $0.name == serviceName }) else {
            return false
        }
        return service.status.localizedCaseInsensitiveContains("pending")
    }

    private var unsupportedView: some View {
        VStack(spacing: 24) {
            GlassCard {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader(L10n.key("agents.software.title"), subtitle: nil, systemImage: "macwindow")
                    Text(L10n.key("agents.software.unsupported"))
                        .font(.callout)
                        .foregroundStyle(Color.white.opacity(0.75))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
    }

    private struct UninstallSoftwareSheet: View {
        let software: InstalledSoftware
        @Binding var command: String
        @Binding var timeout: String
        @Binding var runAsUser: Bool
        let isSubmitting: Bool
        let errorMessage: String?
        let onCancel: () -> Void
        let onConfirm: () -> Void

        @FocusState private var commandFocused: Bool
        @Environment(\.appTheme) private var appTheme

        var body: some View {
            NavigationStack {
                ZStack {
                    DarkGradientBackground()
                        .ignoresSafeArea()

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 24) {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 16) {
                                    SectionHeader(L10n.key("agents.software.uninstall.sectionTitle"), systemImage: "trash.fill")
                                    Text(L10n.key("agents.software.uninstall.instructions"))
                                        .font(.caption)
                                        .foregroundStyle(Color.white.opacity(0.7))

                                    TextEditor(text: $command)
                                        .focused($commandFocused)
                                        .frame(minHeight: 140)
                                        .padding(12)
                                        .background(
                                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                .fill(Color.white.opacity(0.04))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                                )
                                        )
                                        .font(.body)
                                        .foregroundStyle(Color.white)
                                        .textInputAutocapitalization(.never)
                                        .disableAutocorrection(true)

                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(L10n.key("agents.software.uninstall.timeoutLabel"))
                                            .font(.caption2)
                                            .foregroundStyle(Color.white.opacity(0.65))
                                        TextField("1800", text: $timeout)
                                            .platformKeyboardType(.numberPad)
                                            .padding(.vertical, 10)
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
                                    }

                                    Toggle(isOn: $runAsUser) {
                                        Text(L10n.key("agents.software.uninstall.runAsUser"))
                                            .font(.callout)
                                            .foregroundStyle(Color.white)
                                    }
                                    .toggleStyle(SwitchToggleStyle(tint: appTheme.accent))

                                    if let errorMessage {
                                        Text(errorMessage)
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(Color.red)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 28)
                    }
                }
                .navigationTitle(L10n.format("agents.software.uninstall.navigationTitleFormat", software.name))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.key("common.cancel")) { onCancel() }
                            .disabled(isSubmitting)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            onConfirm()
                        } label: {
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text(L10n.key("agents.software.uninstall.action"))
                            }
                        }
                        .disabled(isSubmitting)
                    }
                }
                .keyboardDismissToolbar()
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    commandFocused = true
                }
            }
        }
    }

    private struct SoftwareTile: View {
        let software: InstalledSoftware
        let installDate: String?
        let isUninstalling: Bool
        let onRequestUninstall: (InstalledSoftware) -> Void
        @Environment(\.appTheme) private var appTheme

        private var softwareName: String {
            software.name.nonEmpty ?? L10n.key("agents.software.unnamed")
        }

        private var versionLabel: String? {
            guard let version = software.version.nonEmpty else { return nil }
            return "v\(version)"
        }

        private var sizeLabel: String? {
            guard let size = software.size.nonEmpty else { return nil }
            let normalized = size.replacingOccurrences(of: " ", with: "").lowercased()
            if normalized == "0b" || normalized == "0" { return nil }
            return size
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(softwareName)
                            .font(.headline)
                            .foregroundStyle(Color.white)
                            .fixedSize(horizontal: false, vertical: true)
                        if let publisher = software.publisher.nonEmpty {
                            Text(publisher)
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.7))
                        }
                    }
                    Spacer()
                    uninstallButton
                }

                HStack(spacing: 10) {
                    if let versionLabel {
                        pill(text: versionLabel, color: appTheme.accent)
                    }
                    if let sizeLabel {
                        pill(text: sizeLabel, color: Color.orange)
                    }
                    if let installDate {
                        pill(text: installDate, color: Color.green)
                    }
                }

                if let source = software.source.nonEmpty {
                    detailBox(icon: "shippingbox", text: source)
                }

                if let location = software.location.nonEmpty {
                    detailRow(icon: "folder", text: location)
                }

                if let uninstall = software.uninstall.nonEmpty {
                    detailRow(icon: "terminal", text: uninstall)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .contextMenu {
                if let uninstall = software.uninstall.nonEmpty {
                    Button {
                        UIPasteboard.general.string = uninstall
                    } label: {
                        Label(L10n.key("agents.software.copyUninstallCommand"), systemImage: "doc.on.doc")
                    }
                }
                if let location = software.location.nonEmpty {
                    Button {
                        UIPasteboard.general.string = location
                    } label: {
                        Label(L10n.key("agents.software.copyInstallPath"), systemImage: "folder")
                    }
                }
            }
        }

        private func pill(text: String, color: Color) -> some View {
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(color.opacity(0.18))
                )
        }

        private func detailRow(icon: String, text: String) -> some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appTheme.accent)
                    .frame(width: 18)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
        }

        private func detailBox(icon: String, text: String) -> some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appTheme.accent)
                    .frame(width: 18)
                Text(text)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
        }

        private var uninstallButton: some View {
            let hasCommand = software.uninstall.nonEmpty != nil
            return Button {
                onRequestUninstall(software)
            } label: {
                if isUninstalling {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.red)
                } else {
                    Image(systemName: "trash")
                        .font(.callout.weight(.semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.red)
            .disabled(!hasCommand || isUninstalling)
            .opacity(hasCommand ? 1 : 0.35)
            .accessibilityLabel(L10n.format("agents.software.uninstall.accessibilityLabelFormat", softwareName))
        }
    }

    private struct ServiceTile: View {
        let service: AgentService
        let isActionInProgress: Bool
        let onAction: (AgentService, ServiceAction) -> Void
        @Environment(\.appTheme) private var appTheme

        private var displayName: String {
            service.display_name.nonEmpty ?? service.name
        }

        private var statusColor: Color {
            service.status.localizedCaseInsensitiveContains("running") ? .green : .orange
        }

        private var statusLabel: String {
            if service.status.localizedCaseInsensitiveContains("pending") {
                return L10n.key("agents.services.status.pending")
            }
            if service.status.localizedCaseInsensitiveContains("stopped") {
                return L10n.key("agents.services.status.stopped")
            }
            if service.status.localizedCaseInsensitiveContains("running") {
                return L10n.key("agents.services.status.running")
            }
            return service.status.capitalized
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName)
                            .font(.headline)
                            .foregroundStyle(Color.white)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(service.name)
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.65))
                    }
                    Spacer()
                    serviceActionMenu
                    statusPill
                }

                HStack(spacing: 10) {
                    pill(text: service.start_type, color: appTheme.accent)
                    pill(text: "PID \(service.pid)", color: .purple)
                    if service.autodelay {
                        pill(text: "Auto Delay", color: .blue)
                    }
                }

                detailRow(icon: "person.crop.circle", text: service.username)
                detailRow(icon: "terminal", text: service.binpath)
                if let description = service.description.nonEmpty {
                    detailRow(icon: "text.alignleft", text: description)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }

        private var serviceActionMenu: some View {
            Menu {
                Button {
                    onAction(service, .stop)
                } label: {
                    Label(ServiceAction.stop.label, systemImage: "stop.fill")
                }

                Button {
                    onAction(service, .start)
                } label: {
                    Label(ServiceAction.start.label, systemImage: "play.fill")
                }

                Button {
                    onAction(service, .restart)
                } label: {
                    Label(ServiceAction.restart.label, systemImage: "arrow.clockwise")
                }
            } label: {
                if isActionInProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.callout.weight(.semibold))
                        .frame(width: 24, height: 24)
                }
            }
            .disabled(isActionInProgress)
            .foregroundStyle(Color.white.opacity(0.85))
        }

        private var statusPill: some View {
            Text(statusLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(statusColor.opacity(0.18))
                )
        }

        private func pill(text: String, color: Color) -> some View {
            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(color.opacity(0.18))
                )
        }

        private func detailRow(icon: String, text: String) -> some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appTheme.accent)
                    .frame(width: 18)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
        }
    }
}

// MARK: - AgentHistoryView

struct AgentHistoryView: View {
    let agentId: String
    let baseURL: String
    let apiKey: String
    @AppStorage("lastSeenDateFormat") private var lastSeenDateFormat: String = ""

    @State private var history: [AgentHistoryEntry] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var selectedOutputEntry: AgentHistoryEntry? = nil

    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    var effectiveAPIKey: String {
        KeychainHelper.shared.getAPIKey() ?? apiKey
    }

    var body: some View {
        ZStack {
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    headerCard
                    historyListCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }

            if isLoading {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                ProgressView(L10n.key("agents.history.loading"))
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .navigationTitle(L10n.key("agents.history.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await fetchHistory() }
        }
        .settingsPresentation(
            item: $selectedOutputEntry,
            fullScreen: ProcessInfo.processInfo.isiOSAppOnMac
        ) { entry in
            HistoryOutputSheet(
                title: outputTitle(for: entry),
                output: outputText(for: entry)
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var headerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(L10n.key("agents.history.header.title"), subtitle: headerSubtitle, systemImage: "clock.arrow.circlepath")
                if let errorMessage {
                    banner(message: errorMessage, isError: true)
                }
            }
        }
    }

    private var historyListCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                if history.isEmpty && !isLoading && errorMessage == nil {
                    Text(L10n.key("agents.history.empty"))
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(history) { entry in
                            HistoryTile(
                                entry: entry,
                                formattedTime: formattedDate(entry.time),
                                onShowOutput: { selectedOutputEntry = entry }
                            )
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: history.count)
                }
            }
        }
    }

    private var headerSubtitle: String {
        if isLoading { return L10n.key("common.loading") }
        return history.count == 1
            ? L10n.format("agents.history.count.single", history.count)
            : L10n.format("agents.history.count.multipleFormat", history.count)
    }

    private func formattedDate(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.key("common.notAvailable") }

        if let date = Self.isoFormatterWithFractional.date(from: trimmed)
            ?? Self.isoFormatter.date(from: trimmed) {
            return formatLastSeenDateValue(date, customFormat: lastSeenDateFormat)
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

    private func outputTitle(for entry: AgentHistoryEntry) -> String {
        if let scriptName = entry.script_name?.nonEmpty {
            return scriptName
        }
        if let command = entry.command?.nonEmpty {
            return command
        }
        return entry.type.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func outputText(for entry: AgentHistoryEntry) -> String {
        let stdout = entry.script_results?.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = entry.script_results?.stderr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var sections: [String] = []
        if !stdout.isEmpty {
            sections.append("\(L10n.key("agents.history.detail.stdout"))\n\(stdout)")
        }
        if !stderr.isEmpty {
            sections.append("\(L10n.key("agents.history.detail.stderr"))\n\(stderr)")
        }
        if sections.isEmpty {
            return L10n.key("agents.history.output.empty")
        }
        return sections.joined(separator: "\n\n")
    }

    private struct HistoryTile: View {
        let entry: AgentHistoryEntry
        let formattedTime: String
        let onShowOutput: () -> Void
        @Environment(\.appTheme) private var appTheme

        private var title: String {
            if let scriptName = entry.script_name?.nonEmpty {
                return scriptName
            }
            if let command = entry.command?.nonEmpty {
                return command
            }
            return entry.type
        }

        private var username: String {
            entry.username?.nonEmpty ?? L10n.key("common.unknown")
        }

        private var typeLabel: String {
            entry.type.replacingOccurrences(of: "_", with: " ").capitalized
        }

        private var scriptOrCommand: String {
            if let scriptName = entry.script_name?.nonEmpty {
                return scriptName
            }
            if let command = entry.command?.nonEmpty {
                return command
            }
            return L10n.key("common.notAvailable")
        }

        private var hasOutput: Bool {
            let stdout = entry.script_results?.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = entry.script_results?.stderr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !stdout.isEmpty || !stderr.isEmpty
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                detailRow(icon: "calendar", title: L10n.key("agents.history.detail.time"), value: formattedTime)
                Divider().overlay(Color.white.opacity(0.1))
                detailRow(icon: "bolt.fill", title: L10n.key("agents.history.detail.action"), value: typeLabel)
                Divider().overlay(Color.white.opacity(0.1))
                detailRow(icon: "terminal", title: L10n.key("agents.history.detail.scriptOrCommand"), value: scriptOrCommand)
                Divider().overlay(Color.white.opacity(0.1))
                detailRow(icon: "person.crop.circle", title: L10n.key("agents.history.detail.initiatedBy"), value: username)

                HStack {
                    Spacer()
                    Button {
                        onShowOutput()
                    } label: {
                        Label(L10n.key("agents.history.output.button"), systemImage: "doc.text.magnifyingglass")
                    }
                    .secondaryButton()
                    .disabled(!hasOutput)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .textSelection(.enabled)
        }

        private func detailRow(icon: String, title: String, value: String) -> some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appTheme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.6))
                    Text(value)
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func outputSection(title: String, value: String, isError: Bool = false) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title, subtitle: nil, systemImage: isError ? "exclamationmark.octagon" : "doc.plaintext")
                Text(value)
                    .font(.caption.monospaced())
                    .foregroundStyle(isError ? Color.red.opacity(0.9) : Color.white.opacity(0.85))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
        }

    }

    private struct HistoryOutputSheet: View {
        let title: String
        let output: String
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                ZStack {
                    DarkGradientBackground()
                        .ignoresSafeArea()

                    ScrollView(showsIndicators: true) {
                        VStack(spacing: 16) {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    SectionHeader(L10n.key("agents.history.detail.stdout"), subtitle: nil, systemImage: "doc.plaintext")
                                    Text(output)
                                        .font(.footnote.monospaced())
                                        .foregroundStyle(Color.white.opacity(0.9))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 28)
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.key("common.close")) {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func fetchHistory() async {
        isLoading = true
        errorMessage = nil

        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/\(agentId)/history/") else {
            errorMessage = L10n.key("common.invalidUrl")
            DiagnosticLogger.shared.appendError("Invalid URL in fetching history.")
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
                guard httpResponse.statusCode == 200 else {
                    errorMessage = L10n.format("common.httpErrorFormat", httpResponse.statusCode)
                    DiagnosticLogger.shared.appendError("HTTP Error \(httpResponse.statusCode) in fetching history.")
                    isLoading = false
                    return
                }
            }

            let decodedHistory = try JSONDecoder().decode([AgentHistoryEntry].self, from: data)
            withAnimation(.easeInOut(duration: 0.25)) {
                history = decodedHistory.sorted { $0.time > $1.time }
            }
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Error fetching history: \(error.localizedDescription)")
        }

        isLoading = false
    }
}

// MARK: - AgentNotesView

struct AgentNotesView: View {
    let agentId: String
    let baseURL: String
    let apiKey: String
    @AppStorage("lastSeenDateFormat") private var lastSeenDateFormat: String = ""

    @State private var notes: [Note] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var statusMessage: String? = nil
    @State private var newNoteText: String = ""
    @State private var isSubmittingNote: Bool = false
    @State private var deletingNoteIDs: Set<Int> = [] // Added to track deleting note IDs
    @State private var isComposerPresented: Bool = false

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

    var effectiveAPIKey: String {
        return KeychainHelper.shared.getAPIKey() ?? apiKey
    }

    private var isDemoMode: Bool {
        DemoMode.isEnabled || (baseURL.isDemoEntry && effectiveAPIKey.lowercased() == "demo")
    }

    private static func demoNotes(agentId: String) -> [Note] {
        [
            Note(
                pk: 101,
                entry_time: "2024-08-25T09:14:22Z",
                note: "Demo note: device enrolled, baseline policies applied.",
                username: "demo.user",
                agent_id: agentId
            ),
            Note(
                pk: 102,
                entry_time: "2024-09-02T14:46:00Z",
                note: "Demo note: reboot scheduled after patch window.",
                username: "Demo",
                agent_id: agentId
            ),
            Note(
                pk: 103,
                entry_time: "2024-09-18T18:05:11Z",
                note: "Demo note: user reported intermittent VPN drops.",
                username: "demo.user",
                agent_id: agentId
            )
        ]
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
                ProgressView(L10n.key("agents.notes.loading"))
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .navigationTitle(L10n.key("agents.notes.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await fetchNotes() }
        }
        .settingsPresentation(
            isPresented: $isComposerPresented,
            fullScreen: ProcessInfo.processInfo.isiOSAppOnMac
        ) {
            AddAgentNoteSheet(
                noteText: $newNoteText,
                isSubmitting: isSubmittingNote,
                onCancel: {
                    isComposerPresented = false
                    newNoteText = ""
                },
                onSubmit: { note in
                    Task { await createNote(with: note) }
                }
            )
        }
    }

    private var notesHeaderCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(L10n.key("agents.notes.header.title"), subtitle: headerSubtitle, systemImage: "note.text")
                HStack {
                    Spacer()
                    Button {
                        newNoteText = ""
                        statusMessage = nil
                        isComposerPresented = true
                    } label: {
                        Label(L10n.key("agents.notes.add"), systemImage: "square.and.pencil")
                    }
                    .secondaryButton()
                    .disabled(isSubmittingNote)
                }
                if let errorMessage {
                    banner(message: errorMessage, isError: true)
                }
                if let statusMessage {
                    banner(message: statusMessage, isError: false)
                }
            }
        }
    }

    private var notesListCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                if notes.isEmpty && !isLoading && errorMessage == nil {
                    Text(L10n.key("agents.notes.empty"))
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(notes) { note in
                            NoteTile(
                                note: note,
                                formattedDate: formattedNoteDate(note.entry_time),
                                isDeleting: deletingNoteIDs.contains(note.id),
                                onDelete: { selected in
                                    Task { await deleteNote(selected) }
                                }
                            )
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: notes.count)
                }
            }
        }
    }

    private var headerSubtitle: String {
        if isLoading { return L10n.key("common.loading") }
        return notes.count == 1
            ? L10n.format("agents.notes.count.single", notes.count)
            : L10n.format("agents.notes.count.multipleFormat", notes.count)
    }

    private func formattedNoteDate(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.key("common.notAvailable") }

        if let parsed = AgentNotesView.noteISOFormatterWithFractional.date(from: trimmed)
            ?? AgentNotesView.noteISOFormatter.date(from: trimmed)
            ?? AgentNotesView.noteFallbackParser.date(from: trimmed) {
            return formatLastSeenDateValue(parsed, customFormat: lastSeenDateFormat)
        }

        return trimmed
    }

    private func noteResponseMessage(from data: Data) -> String {
        if data.isEmpty { return L10n.key("agents.notes.added") }
        if let decoded = try? JSONDecoder().decode(String.self, from: data) {
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return L10n.key("agents.notes.added") }
            if trimmed.lowercased().hasPrefix("note added") { return L10n.key("agents.notes.added") }
            return trimmed
        }

        var raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
            raw.removeFirst()
            raw.removeLast()
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if raw.isEmpty { return L10n.key("agents.notes.added") }
        if raw.lowercased().hasPrefix("note added") { return L10n.key("agents.notes.added") }
        return raw
    }

    private struct AddAgentNoteSheet: View {
        @Binding var noteText: String
        let isSubmitting: Bool
        let onCancel: () -> Void
        let onSubmit: (String) -> Void

        @FocusState private var editorFocused: Bool
        @Environment(\.dismiss) private var dismiss

        private var trimmedNote: String {
            noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    DarkGradientBackground()
                        .ignoresSafeArea()

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 24) {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text(L10n.key("agents.notes.editor.label"))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color.white.opacity(0.65))

                                    TextEditor(text: $noteText)
                                        .focused($editorFocused)
                                        .frame(minHeight: 220)
                                        .padding(12)
                                        .background(
                                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                .fill(Color.white.opacity(0.04))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                                )
                                        )
                                        .font(.body)
                                        .foregroundStyle(Color.white)
                                        .textInputAutocapitalization(.sentences)

                                    HStack {
                                        Spacer()
                                        Text(L10n.format("agents.notes.editor.charCountFormat", noteText.count))
                                            .font(.caption2)
                                            .foregroundStyle(Color.white.opacity(0.55))
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 28)
                    }
                }
                .navigationTitle(L10n.key("agents.notes.new.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.key("common.cancel")) {
                            onCancel()
                            dismiss()
                        }
                            .disabled(isSubmitting)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            onSubmit(trimmedNote)
                        } label: {
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text(L10n.key("common.save"))
                            }
                        }
                        .disabled(isSubmitting || trimmedNote.isEmpty)
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    editorFocused = true
                }
            }
        }
    }

    @MainActor
    func createNote(with note: String) async {
        if isDemoMode {
            let nextId = (notes.map { $0.pk }.max() ?? 100) + 1
            let newNote = Note(
                pk: nextId,
                entry_time: ISO8601DateFormatter().string(from: Date()),
                note: note,
                username: "Demo",
                agent_id: agentId
            )
            withAnimation(.easeInOut(duration: 0.25)) {
                notes.insert(newNote, at: 0)
            }
            newNoteText = ""
            statusMessage = L10n.key("agents.notes.added")
            isComposerPresented = false
            return
        }
        if ApiErrorSimulation.isEnabled {
            errorMessage = "HTTP Error: 401"
            statusMessage = nil
            return
        }
        guard !note.isEmpty else {
            errorMessage = L10n.key("agents.notes.error.empty")
            statusMessage = nil
            return
        }

        isSubmittingNote = true
        defer { isSubmittingNote = false }

        errorMessage = nil
        statusMessage = nil

        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/notes/") else {
            errorMessage = L10n.key("common.invalidUrl")
            DiagnosticLogger.shared.appendError("Invalid URL when creating agent note.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addDefaultHeaders(apiKey: effectiveAPIKey)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "agent_id": agentId,
            "note": note
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            errorMessage = "Error preparing request: \(error.localizedDescription)"
            DiagnosticLogger.shared.appendError("Error encoding note payload: \(error.localizedDescription)")
            return
        }

        DiagnosticLogger.shared.logHTTPRequest(method: "POST", url: url.absoluteString, headers: request.allHTTPHeaderFields ?? [:])
        DiagnosticLogger.shared.append("Body: \(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                DiagnosticLogger.shared.logHTTPResponse(method: "POST", url: url.absoluteString, status: httpResponse.statusCode, data: data)
                guard (200...299).contains(httpResponse.statusCode) else {
                    errorMessage = "HTTP Error: \(httpResponse.statusCode)"
                    DiagnosticLogger.shared.appendError("HTTP Error \(httpResponse.statusCode) when creating note.")
                    return
                }
            }

            let successMessage = noteResponseMessage(from: data)
            newNoteText = ""

            await fetchNotes()
            if errorMessage == nil {
                statusMessage = successMessage
                isComposerPresented = false
            }
        } catch {
            errorMessage = "Error adding note: \(error.localizedDescription)"
            DiagnosticLogger.shared.appendError("Error adding note: \(error.localizedDescription)")
        }
    }

    @MainActor
    func deleteNote(_ note: Note) async {
        if isDemoMode {
            withAnimation(.easeInOut(duration: 0.25)) {
                notes.removeAll { $0.pk == note.pk }
            }
            statusMessage = L10n.key("agents.notes.deleted")
            return
        }
        if ApiErrorSimulation.isEnabled {
            errorMessage = L10n.format("common.httpErrorFormat", 401)
            statusMessage = nil
            return
        }
        errorMessage = nil
        statusMessage = nil

        deletingNoteIDs.insert(note.id)
        defer { deletingNoteIDs.remove(note.id) }

        let sanitizedURL = baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(sanitizedURL)/agents/notes/\(note.id)/") else {
            errorMessage = L10n.key("common.invalidUrl")
            DiagnosticLogger.shared.appendError("Invalid URL when deleting agent note.")
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
                guard (200...299).contains(httpResponse.statusCode) else {
                    errorMessage = L10n.format("common.httpErrorFormat", httpResponse.statusCode)
                    DiagnosticLogger.shared.appendError("HTTP Error \(httpResponse.statusCode) when deleting note.")
                    return
                }
            }

            await fetchNotes()
            if errorMessage == nil {
                statusMessage = L10n.key("agents.notes.deleted")
            }
        } catch {
            errorMessage = L10n.format("agents.notes.error.deleteFormat", error.localizedDescription)
            DiagnosticLogger.shared.appendError("Error deleting note: \(error.localizedDescription)")
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

    private struct NoteTile: View {
        let note: Note
        let formattedDate: String
        let isDeleting: Bool
        let onDelete: (Note) -> Void
        @State private var isConfirmingDelete = false

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
                    Spacer(minLength: 0)
                    deleteButton
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
            .contextMenu {
                Button(role: .destructive) {
                    onDelete(note)
                } label: {
                    Label("Delete Note", systemImage: "trash")
                }
                .disabled(isDeleting)
            }
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

        private var deleteButton: some View {
            Button {
                isConfirmingDelete = true
            } label: {
                if isDeleting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.red)
                        .frame(height: 20)
                } else {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .font(.callout)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.red)
            .disabled(isDeleting)
            .confirmationDialog("Delete this note?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    onDelete(note)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This action permanently removes the note.")
            }
        }
    }

    @MainActor
    func fetchNotes() async {
        if isDemoMode {
            isLoading = true
            errorMessage = nil
            statusMessage = nil
            withAnimation(.easeInOut(duration: 0.25)) {
                notes = Self.demoNotes(agentId: agentId)
            }
            isLoading = false
            return
        }
        if ApiErrorSimulation.isEnabled {
            isLoading = true
            errorMessage = L10n.format("agents.error.http", 401)
            statusMessage = nil
            isLoading = false
            return
        }
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
            withAnimation(.easeInOut(duration: 0.25)) {
                notes = decodedNotes
            }
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
    @AppStorage("lastSeenDateFormat") private var lastSeenDateFormat: String = ""

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
            return L10n.format("agents.tasks.result.truncatedFormat", truncated)
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
                ProgressView(L10n.key("agents.tasks.loading"))
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .navigationTitle(L10n.key("agents.tasks.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await fetchTasks() }
        }
    }

    private var tasksHeaderCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(L10n.key("agents.tasks.header.title"), subtitle: headerSubtitle, systemImage: "checklist")
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
                    Text(L10n.key("agents.tasks.empty"))
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.65))
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(tasks) { task in
                            TaskTile(task: task, formattedRunTime: formattedDate(task.run_time_date), formattedCreated: formattedDate(task.created_time), truncate: truncatedResult)
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: tasks.count)
                }
            }
        }
    }

    private var headerSubtitle: String {
        if isLoading { return L10n.key("common.loading") }
        return tasks.count == 1
            ? L10n.format("agents.tasks.count.single", tasks.count)
            : L10n.format("agents.tasks.count.multipleFormat", tasks.count)
    }

    private func formattedDate(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.key("common.notAvailable") }
        if let date = isoFormatter.date(from: trimmed)
            ?? isoNoFractionFormatter.date(from: trimmed)
            ?? noTZDateParser.date(from: trimmed) {
            return formatLastSeenDateValue(date, customFormat: lastSeenDateFormat)
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

    private struct TaskTile: View {
        let task: AgentTask
        let formattedRunTime: String
        let formattedCreated: String
        let truncate: (String) -> String
        @Environment(\.appTheme) private var appTheme

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(task.name)
                    .font(.headline)
                    .foregroundStyle(Color.white)

                detailRow(title: L10n.key("agents.tasks.detail.schedule"), value: task.schedule, system: "calendar")
                detailRow(title: L10n.key("agents.tasks.detail.nextRun"), value: formattedRunTime, system: "clock")
                detailRow(title: L10n.key("agents.tasks.detail.created"), value: "\(task.created_by) • \(formattedCreated)", system: "person")

                if let result = task.task_result {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(L10n.key("agents.tasks.result.title"), subtitle: result.status.capitalized, systemImage: "text.justify")
                        Text(truncate(result.stdout))
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let actions = task.actions, !actions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeader(L10n.key("agents.tasks.actions.title"), subtitle: L10n.format("agents.tasks.actions.subtitleFormat", actions.count), systemImage: "bolt.badge.clock")
                        ForEach(actions, id: \.name) { action in
                            HStack(spacing: 8) {
                                Image(systemName: "arrowtriangle.forward.fill")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(appTheme.accent)
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
                    .foregroundStyle(appTheme.accent)
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
            withAnimation(.easeInOut(duration: 0.25)) {
                tasks = decodedTasks
            }
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Error fetching tasks: \(error.localizedDescription)")
        }
        isLoading = false
    }
}

// MARK: – AgentCustomFieldsView
struct AgentCustomFieldsView: View {
    let customFields: [AgentCustomField]

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
        .navigationTitle(L10n.key("agents.management.customFields.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerCard: some View {
        GlassCard {
            SectionHeader(L10n.key("agents.management.customFields.title"), subtitle: headerSubtitle, systemImage: "slider.horizontal.3")
        }
    }

    private var fieldsCard: some View {
        GlassCard {
            if customFields.isEmpty {
                Text(L10n.key("agents.customFields.empty"))
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
        let field: AgentCustomField
        @Environment(\.appTheme) private var appTheme

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "number")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(appTheme.accent)
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
    @AppStorage("lastSeenDateFormat") private var lastSeenDateFormat: String = ""

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
                ProgressView(L10n.key("agents.checks.loading"))
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
            }
        }
        .navigationTitle(L10n.key("agents.checks.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await fetchChecks() }
        }
    }

    private var headerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(L10n.key("agents.checks.header.title"), subtitle: headerSubtitle, systemImage: "waveform.path.ecg")
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
                    Text(L10n.key("agents.checks.empty"))
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
                    .animation(.easeInOut(duration: 0.25), value: checks.count)
                }
            }
        }
    }

    private var headerSubtitle: String {
        if isLoading { return L10n.key("common.loading") }
        return checks.count == 1
            ? L10n.format("agents.checks.count.single", checks.count)
            : L10n.format("agents.checks.count.multipleFormat", checks.count)
    }

    private func formattedDate(_ raw: String?) -> String {
        guard let raw else { return L10n.key("common.unknown") }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.key("common.unknown") }
        if let date = Self.iso8601Formatter.date(from: trimmed)
            ?? Self.iso8601NoFractionFormatter.date(from: trimmed)
            ?? Self.noTimeZoneFormatter.date(from: trimmed) {
            return formatLastSeenDateValue(date, customFormat: lastSeenDateFormat)
        }
        return trimmed
    }

    private func statusInfo(for status: String?) -> (text: String, color: Color, icon: String) {
        let normalized = status?.lowercased() ?? "unknown"
        switch normalized {
        case let value where value.contains("pass"):
            return (text: status?.capitalized ?? L10n.key("agents.checks.status.passing"), color: Color.green, icon: "checkmark.circle.fill")
        case let value where value.contains("warn"):
            return (text: status?.capitalized ?? L10n.key("agents.checks.status.warning"), color: Color.orange, icon: "exclamationmark.triangle.fill")
        case let value where value.contains("fail") || value.contains("error"):
            return (text: status?.capitalized ?? L10n.key("agents.checks.status.failing"), color: Color.red, icon: "xmark.octagon.fill")
        default:
            return (text: status?.capitalized ?? L10n.key("agents.checks.status.unknown"), color: Color.gray, icon: "questionmark.circle.fill")
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

                infoRow(title: L10n.key("agents.checks.detail.lastRun"), value: formattedLastRun)
                infoRow(title: L10n.key("agents.checks.detail.created"), value: "\(check.created_by) • \(formattedCreated)")

                if let severity = check.check_result?.alert_severity?.capitalized, !severity.isEmpty {
                    infoRow(title: L10n.key("agents.checks.detail.alertSeverity"), value: severity)
                }

                if let stdout = check.check_result?.stdout?.nonEmpty {
                    outputSection(title: L10n.key("agents.checks.output.title"), value: truncatedOutput(stdout))
                } else if let info = check.check_result?.more_info?.nonEmpty {
                    outputSection(title: L10n.key("agents.checks.output.details"), value: truncatedOutput(info))
                }

                if let stderr = check.check_result?.stderr?.nonEmpty {
                    outputSection(title: L10n.key("agents.checks.output.errors"), value: truncatedOutput(stderr), isError: true)
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
            withAnimation(.easeInOut(duration: 0.25)) {
                checks = decoded
            }
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Error fetching checks: \(error.localizedDescription)")
            print("Error fetching checks: \(error.localizedDescription)")
        }

        isLoading = false
    }


}
