import SwiftUI

struct ScriptManagerView: View {
    let settings: RMMSettings
    @Environment(\.appTheme) private var appTheme

    @ObservedObject private var agentCache = AgentCache.shared
    @State private var scripts: [ScriptSummary] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var searchText: String = ""
    @State private var selectedScript: ScriptSummary?
    @State private var scriptDetail: ScriptDetail?
    @State private var isLoadingDetail = false
    @State private var detailError: String?
    @State private var detailFetchedAt: Date?
    @State private var pendingDeleteScript: ScriptSummary?
    @State private var isDeletingScript = false
    @State private var actionAlertMessage: String?
    @State private var editDraft = ScriptEditDraft()
    @State private var isEditingScript = false
    @State private var editError: String?
    @State private var isSavingEdit = false
    @State private var testContext: ScriptTestContext?
    @State private var isTestingScript = false
    @State private var testResult: ScriptTestResponse?
    @State private var testError: String?

    var body: some View {
        ZStack {
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 18) {
                            SectionHeader(L10n.key("scripts.title"), subtitle: L10n.key("scripts.subtitle"), systemImage: "terminal.fill")

                            searchField()

                            statusContent()
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }
        }
        .navigationTitle(L10n.key("scripts.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadScripts(force: true) }
        .refreshable { await loadScripts(force: true) }
        .sheet(item: $selectedScript) { summary in
            ScriptDetailSheet(
                summary: summary,
                detail: scriptDetail,
                isLoading: isLoadingDetail,
                errorMessage: detailError,
                fetchedAt: detailFetchedAt,
                isDeleting: isDeletingScript,
                isTesting: isTestingScript,
                canTest: !agentCache.agents.isEmpty,
                isSavingEdit: isSavingEdit,
                onRetry: {
                    Task { await loadScriptDetail(for: summary, force: true) }
                },
                onTest: {
                    if let detail = scriptDetail {
                        prepareTestContext(summary: summary, detail: detail)
                    }
                },
                onEdit: {
                    if let detail = scriptDetail {
                        prepareEditDraft(summary: summary, detail: detail)
                    }
                },
                onDelete: {
                    pendingDeleteScript = summary
                }
            )
            .task {
                await loadScriptDetail(for: summary, force: true)
            }
        }
        .sheet(item: $testContext) { context in
            ScriptTestSheet(
                context: context,
                agents: agentCache.agents,
                isTesting: $isTestingScript,
                result: $testResult,
                errorMessage: $testError,
                onRun: { draft in
                    await runScriptTest(context: context, draft: draft)
                }
            )
        }
        .sheet(isPresented: $isEditingScript) {
            if let detail = scriptDetail {
                ScriptEditSheet(
                    draft: $editDraft,
                    isSaving: $isSavingEdit,
                    errorMessage: $editError,
                    onSave: {
                        await saveScriptChanges(detail: detail)
                    }
                )
            }
        }
        .alert(L10n.key("common.error"), isPresented: Binding(
            get: { loadError != nil && scripts.isEmpty },
            set: { if !$0 { loadError = nil } }
        )) {
            Button(L10n.key("common.dismiss"), role: .cancel) { }
        } message: {
            if let loadError {
                Text(loadError)
            }
        }
        .alert(L10n.key("common.notice"), isPresented: Binding(
            get: { actionAlertMessage != nil },
            set: { if !$0 { actionAlertMessage = nil } }
        )) {
            Button(L10n.key("common.ok"), role: .cancel) { }
        } message: {
            if let actionAlertMessage {
                Text(actionAlertMessage)
            }
        }
        .confirmationDialog(
            L10n.key("scripts.delete.title"),
            isPresented: Binding(
                get: { pendingDeleteScript != nil },
                set: { if !$0 { pendingDeleteScript = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.key("common.delete"), role: .destructive) {
                if let script = pendingDeleteScript {
                    Task { await deleteScript(script) }
                }
            }
            Button(L10n.key("common.cancel"), role: .cancel) { pendingDeleteScript = nil }
        } message: {
            if let script = pendingDeleteScript {
                Text(L10n.format("scripts.delete.message", script.name))
            }
        }
    }

    @ViewBuilder
    private func searchField() -> some View {
        TextField(L10n.key("scripts.search.placeholder"), text: $searchText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
            .foregroundStyle(Color.white)
    }

    @ViewBuilder
    private func statusContent() -> some View {
        if isLoading && scripts.isEmpty {
            HStack(spacing: 12) {
                ProgressView()
                Text(L10n.key("scripts.loading"))
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        } else if let loadError, scripts.isEmpty {
            VStack(spacing: 12) {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(Color.red)
                Button {
                    Task { await loadScripts(force: true) }
                } label: {
                    Label(L10n.key("common.retry"), systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .primaryButton()
            }
        } else if filteredScripts.isEmpty {
            Text(L10n.key("scripts.empty.filtered"))
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.7))
        } else {
            scriptList()
        }
    }

    private var filteredScripts: [ScriptSummary] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return scripts }
        return scripts.filter { summary in
            let query = trimmed.lowercased()
            if summary.name.lowercased().contains(query) { return true }
            if let description = summary.description?.lowercased(), description.contains(query) { return true }
            if let category = summary.category?.lowercased(), category.contains(query) { return true }
            return false
        }
    }

    @ViewBuilder
    private func scriptList() -> some View {
        VStack(spacing: 14) {
            ForEach(filteredScripts) { summary in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(summary.name)
                                    .font(.headline)
                                    .foregroundStyle(Color.white)
                                if summary.favorite == true {
                                    Image(systemName: "star.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.yellow)
                                }
                            }
                            if let description = summary.description, !description.isEmpty {
                                Text(description)
                                    .font(.footnote)
                                    .foregroundStyle(Color.white.opacity(0.7))
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            if let category = summary.category, !category.isEmpty {
                                Text(category)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.white.opacity(0.08))
                                    )
                            }
                            Text(summary.shell.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(appTheme.accent)
                        }
                    }

                    ScriptMetaRow(summary: summary)

                    Button {
                        presentDetail(for: summary)
                    } label: {
                        Label(L10n.key("scripts.viewDetails"), systemImage: "doc.text.magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .secondaryButton()
                }
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
        }
    }

    private func presentDetail(for summary: ScriptSummary) {
        scriptDetail = nil
        detailError = nil
        detailFetchedAt = nil
        selectedScript = summary
    }

    private func loadScripts(force: Bool = false) async {
        guard !isLoading || force else { return }

        if settings.baseURL.isDemoEntry {
            await MainActor.run {
                scripts = ScriptSummary.demoScripts
                loadError = nil
                isLoading = false
            }
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            await MainActor.run { loadError = L10n.key("scripts.error.missingApiKey") }
            return
        }

        guard let request = makeRequest(path: "/scripts/", method: "GET", apiKey: apiKey) else {
            await MainActor.run { loadError = L10n.key("scripts.error.invalidBaseUrl") }
            return
        }

        await MainActor.run {
            isLoading = true
            loadError = nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ScriptManagerError.unexpected }

            DiagnosticLogger.shared.logHTTPResponse(
                method: "GET",
                url: request.url?.absoluteString ?? "",
                status: http.statusCode,
                data: data
            )

            switch http.statusCode {
            case 200:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let decoded = try decoder.decode([ScriptSummary].self, from: data)
                await MainActor.run {
                    scripts = decoded
                    loadError = nil
                }
            case 401:
                throw ScriptManagerError.message(L10n.key("scripts.error.invalidApiKey"))
            default:
                throw ScriptManagerError.message(L10n.format("scripts.error.httpLoad", http.statusCode))
            }
        } catch ScriptManagerError.message(let message) {
            await MainActor.run { loadError = message }
        } catch {
            await MainActor.run { loadError = error.localizedDescription }
            DiagnosticLogger.shared.appendError("Failed to load scripts: \(error.localizedDescription)")
        }

        await MainActor.run { isLoading = false }
    }

    private func loadScriptDetail(for summary: ScriptSummary, force: Bool = false) async {
        guard selectedScript?.id == summary.id else { return }
        guard !isLoadingDetail || force else { return }

        if settings.baseURL.isDemoEntry {
            await MainActor.run {
                scriptDetail = ScriptDetail.demoScript(for: summary)
                detailError = nil
                isLoadingDetail = false
                detailFetchedAt = Date()
            }
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            await MainActor.run { detailError = L10n.key("scripts.error.missingApiKey") }
            return
        }

        guard let request = makeRequest(path: "/scripts/\(summary.id)/", method: "GET", apiKey: apiKey) else {
            await MainActor.run { detailError = L10n.key("scripts.error.invalidBaseUrl") }
            return
        }

        await MainActor.run {
            isLoadingDetail = true
            detailError = nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ScriptManagerError.unexpected }

            DiagnosticLogger.shared.logHTTPResponse(
                method: "GET",
                url: request.url?.absoluteString ?? "",
                status: http.statusCode,
                data: data
            )

            switch http.statusCode {
            case 200:
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let decoded = try decoder.decode(ScriptDetail.self, from: data)
                if selectedScript?.id == summary.id {
                    await MainActor.run {
                        scriptDetail = decoded
                        detailError = nil
                        detailFetchedAt = Date()
                    }
                }
            case 401:
                throw ScriptManagerError.message(L10n.key("scripts.error.invalidApiKey"))
            default:
                throw ScriptManagerError.message(L10n.format("scripts.error.httpLoadDetail", http.statusCode))
            }
        } catch ScriptManagerError.message(let message) {
            if selectedScript?.id == summary.id {
                await MainActor.run { detailError = message }
            }
        } catch {
            if selectedScript?.id == summary.id {
                await MainActor.run { detailError = error.localizedDescription }
            }
            DiagnosticLogger.shared.appendError("Failed to load script detail: \(error.localizedDescription)")
        }

        await MainActor.run { isLoadingDetail = false }
    }

    private func prepareEditDraft(summary: ScriptSummary, detail: ScriptDetail) {
        let isBuiltIn = (detail.scriptType ?? summary.scriptType)?.lowercased() == "builtin"
        if isBuiltIn {
            actionAlertMessage = L10n.key("scripts.error.builtinNoEdit")
            return
        }

        editDraft = ScriptEditDraft(detail: detail)
        editError = nil
        selectedScript = nil
        DispatchQueue.main.async {
            isEditingScript = true
        }
    }

    private func prepareTestContext(summary: ScriptSummary, detail: ScriptDetail) {
        guard !agentCache.agents.isEmpty else {
            actionAlertMessage = L10n.key("scripts.error.noAgentsShort")
            return
        }
        testError = nil
        testResult = nil
        let context = ScriptTestContext(summary: summary, detail: detail)
        selectedScript = nil
        DispatchQueue.main.async {
            testContext = context
        }
    }

    private func deleteScript(_ summary: ScriptSummary) async {
        guard !isDeletingScript else { return }

        await MainActor.run {
            isDeletingScript = true
            pendingDeleteScript = nil
        }

        defer {
            Task { @MainActor in isDeletingScript = false }
        }

        if settings.baseURL.isDemoEntry {
            await MainActor.run {
                scripts.removeAll { $0.id == summary.id }
                if selectedScript?.id == summary.id {
                    selectedScript = nil
                    scriptDetail = nil
                }
                actionAlertMessage = L10n.key("scripts.status.deletedDemo")
            }
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            await MainActor.run { actionAlertMessage = L10n.key("scripts.error.missingApiKey") }
            return
        }

        guard let request = makeRequest(path: "/scripts/\(summary.id)/", method: "DELETE", apiKey: apiKey) else {
            await MainActor.run { actionAlertMessage = L10n.key("scripts.error.invalidBaseUrl") }
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ScriptManagerError.unexpected }

            DiagnosticLogger.shared.logHTTPResponse(
                method: "DELETE",
                url: request.url?.absoluteString ?? "",
                status: http.statusCode,
                data: data
            )

            switch http.statusCode {
            case 200, 202, 204:
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    scripts.removeAll { $0.id == summary.id }
                    if selectedScript?.id == summary.id {
                        selectedScript = nil
                        scriptDetail = nil
                    }
                    actionAlertMessage = message?.nonEmpty ?? L10n.key("scripts.status.deleted")
                }
            case 401:
                throw ScriptManagerError.message(L10n.key("scripts.error.invalidApiKey"))
            default:
                let responseText = String(data: data, encoding: .utf8) ?? ""
                throw ScriptManagerError.message(L10n.format("scripts.error.httpDelete", http.statusCode, responseText))
            }
        } catch ScriptManagerError.message(let message) {
            await MainActor.run { actionAlertMessage = message }
        } catch {
            await MainActor.run { actionAlertMessage = error.localizedDescription }
            DiagnosticLogger.shared.appendError("Failed to delete script: \(error.localizedDescription)")
        }
    }

    private func saveScriptChanges(detail: ScriptDetail) async {
        guard !isSavingEdit else { return }

        do {
            let payload = try editDraft.makePayload(existing: detail)

            if settings.baseURL.isDemoEntry {
                await MainActor.run {
                    scriptDetail = ScriptDetail(
                        id: payload.id,
                        name: payload.name,
                        description: payload.description,
                        shell: payload.shell,
                        args: payload.args,
                        category: payload.category,
                        favorite: payload.favorite,
                        scriptBody: payload.scriptBody,
                        defaultTimeout: payload.defaultTimeout,
                        syntax: payload.syntax,
                        filename: payload.filename,
                        hidden: payload.hidden,
                        supportedPlatforms: payload.supportedPlatforms,
                        runAsUser: payload.runAsUser,
                        envVars: payload.envVars.map { ScriptEnvironmentVariable(id: nil, name: $0.name, value: $0.value) },
                        scriptType: payload.scriptType,
                        scriptHash: detail.scriptHash
                    )
                    isEditingScript = false
                    actionAlertMessage = L10n.key("scripts.status.updatedDemo")
                }
                return
            }

            guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
                await MainActor.run { editError = L10n.key("scripts.error.missingApiKey") }
                return
            }

            guard var request = makeRequest(path: "/scripts/\(detail.id)/", method: "PUT", apiKey: apiKey) else {
                await MainActor.run { editError = L10n.key("scripts.error.invalidBaseUrl") }
                return
            }

            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.withoutEscapingSlashes]
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(payload)

            await MainActor.run {
                isSavingEdit = true
                editError = nil
            }

            defer {
                Task { @MainActor in isSavingEdit = false }
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ScriptManagerError.unexpected }

            DiagnosticLogger.shared.logHTTPResponse(
                method: "PUT",
                url: request.url?.absoluteString ?? "",
                status: http.statusCode,
                data: data
            )

            switch http.statusCode {
            case 200, 202, 204:
                await loadScripts(force: true)
                if let current = selectedScript {
                    await loadScriptDetail(for: current, force: true)
                }
                await MainActor.run {
                    isEditingScript = false
                    actionAlertMessage = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? L10n.key("scripts.status.updated")
                }
            case 400:
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    editError = message?.nonEmpty ?? L10n.key("scripts.error.serverRejectedUpdate")
                }
            case 401:
                throw ScriptManagerError.message(L10n.key("scripts.error.invalidApiKey"))
            default:
                let message = String(data: data, encoding: .utf8) ?? ""
                throw ScriptManagerError.message(L10n.format("scripts.error.httpUpdate", http.statusCode, message))
            }
        } catch ScriptDraftError.message(let message) {
            await MainActor.run { editError = message }
        } catch ScriptManagerError.message(let message) {
            await MainActor.run { editError = message }
        } catch {
            await MainActor.run { editError = error.localizedDescription }
            DiagnosticLogger.shared.appendError("Failed to update script: \(error.localizedDescription)")
        }
    }

    private func runScriptTest(context: ScriptTestContext, draft: ScriptTestDraft) async {
        guard !isTestingScript else { return }

        do {
            let (agentID, payload) = try draft.makePayload()

            if settings.baseURL.isDemoEntry {
                await MainActor.run {
                    testResult = ScriptTestResponse.demo
                    testError = nil
                }
                return
            }

            guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
                await MainActor.run { testError = L10n.key("scripts.error.missingApiKey") }
                return
            }

            guard var request = makeRequest(path: "/scripts/\(agentID)/test/", method: "POST", apiKey: apiKey) else {
                await MainActor.run { testError = L10n.key("scripts.error.invalidBaseUrl") }
                return
            }

            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.withoutEscapingSlashes]
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(payload)

            await MainActor.run {
                isTestingScript = true
                testError = nil
                testResult = nil
            }

            defer {
                Task { @MainActor in isTestingScript = false }
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ScriptManagerError.unexpected }

            DiagnosticLogger.shared.logHTTPResponse(
                method: "POST",
                url: request.url?.absoluteString ?? "",
                status: http.statusCode,
                data: data
            )

            switch http.statusCode {
            case 200, 201, 202:
                let decoder = JSONDecoder()
                if let decoded = try? decoder.decode(ScriptTestResponse.self, from: data) {
                    await MainActor.run {
                        testResult = decoded
                        testError = nil
                    }
                } else {
                    let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    DiagnosticLogger.shared.appendWarning("Unexpected test response payload: \(message ?? "<empty>")")
                    await MainActor.run {
                        testResult = nil
                        testError = message?.nonEmpty ?? L10n.key("scripts.test.error.responseParse")
                    }
                }
            case 400:
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run { testError = message?.nonEmpty ?? L10n.key("scripts.test.error.executionFailed") }
            case 401:
                throw ScriptManagerError.message(L10n.key("scripts.error.invalidApiKey"))
            default:
                throw ScriptManagerError.message(L10n.format("scripts.test.error.http", http.statusCode))
            }
        } catch ScriptDraftError.message(let message) {
            await MainActor.run { testError = message }
        } catch ScriptManagerError.message(let message) {
            await MainActor.run { testError = message }
        } catch {
            await MainActor.run { testError = error.localizedDescription }
            DiagnosticLogger.shared.appendError("Failed to run script test: \(error.localizedDescription)")
        }
    }

    private func makeRequest(path: String, method: String, apiKey: String) -> URLRequest? {
        let base = settings.baseURL.removingTrailingSlash()
        guard let url = URL(string: base + path) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.addDefaultHeaders(apiKey: apiKey)

        DiagnosticLogger.shared.logHTTPRequest(
            method: method,
            url: url.absoluteString,
            headers: request.allHTTPHeaderFields ?? [:]
        )

        return request
    }
}

private enum ScriptManagerError: Error {
    case message(String)
    case unexpected
}

private struct ScriptSummary: Identifiable, Codable, Equatable {
    let id: Int
    let name: String
    let description: String?
    let scriptType: String?
    let shell: String
    let args: [String]?
    let category: String?
    let favorite: Bool?
    let defaultTimeout: Int?
    let syntax: String?
    let filename: String?
    let hidden: Bool?
    let supportedPlatforms: [String]?
    let runAsUser: Bool?
    let envVars: [ScriptEnvironmentVariable]?

    static let demoScripts: [ScriptSummary] = [
        ScriptSummary(
            id: 1,
            name: "Demo Script",
            description: "Example script entry for demo instances.",
            scriptType: "builtin",
            shell: "powershell",
            args: ["-demo"],
            category: "Demo",
            favorite: true,
            defaultTimeout: 120,
            syntax: "demo [--flag]",
            filename: "demo_script.ps1",
            hidden: false,
            supportedPlatforms: ["windows"],
            runAsUser: false,
            envVars: []
        )
    ]
}

private struct ScriptEnvironmentVariable: Codable, Hashable, Identifiable {
    let id: Int?
    let name: String?
    let value: String?
}

private struct ScriptDetail: Codable {
    let id: Int
    let name: String
    let description: String?
    let shell: String
    let args: [String]?
    let category: String?
    let favorite: Bool?
    let scriptBody: String?
    let defaultTimeout: Int?
    let syntax: String?
    let filename: String?
    let hidden: Bool?
    let supportedPlatforms: [String]?
    let runAsUser: Bool?
    let envVars: [ScriptEnvironmentVariable]?
    let scriptType: String?
    let scriptHash: String?

    static func demoScript(for summary: ScriptSummary) -> ScriptDetail {
        ScriptDetail(
            id: summary.id,
            name: summary.name,
            description: summary.description,
            shell: summary.shell,
            args: summary.args,
            category: summary.category,
            favorite: summary.favorite,
            scriptBody: "echo 'Demo script body'",
            defaultTimeout: summary.defaultTimeout,
            syntax: summary.syntax,
            filename: summary.filename,
            hidden: summary.hidden,
            supportedPlatforms: summary.supportedPlatforms,
            runAsUser: summary.runAsUser,
            envVars: summary.envVars,
            scriptType: summary.scriptType,
            scriptHash: nil
        )
    }
}

private struct ScriptTestContext: Identifiable {
    let summary: ScriptSummary
    let detail: ScriptDetail

    var id: Int { summary.id }
}

private struct ScriptTestResponse: Decodable, Equatable {
    let stdout: String
    let stderr: String
    let retcode: Int
    let executionTime: Double?
    let id: Int?

    static let demo = ScriptTestResponse(
        stdout: "[12:00:00] Demo run\n",
        stderr: "",
        retcode: 0,
        executionTime: 1.0,
        id: 0
    )
}

private struct ScriptEnvironmentVariablePayload: Encodable, Equatable, Hashable {
    let name: String
    let value: String?
}

private struct ScriptTestPayload: Encodable {
    let code: String
    let timeout: Int
    let args: [String]
    let shell: String
    let runAsUser: Bool
    let envVars: [ScriptEnvironmentVariablePayload]
}

private enum ScriptShellOptions {
    static let base: [String] = ["python", "powershell", "bash", "nushell", "deno"]
    static let customTag = "__custom__"

    static func selection(for value: String) -> (selection: String, custom: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (base.first ?? customTag, "")
        }

        if let match = base.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return (match, "")
        }

        return (customTag, trimmed)
    }

    static func displayName(for value: String) -> String {
        switch value.lowercased() {
        case "powershell":
            return "PowerShell"
        case "nushell":
            return "NuShell"
        case "bash":
            return "Bash"
        case "python":
            return "Python"
        case "deno":
            return "Deno"
        default:
            return value
        }
    }

    static func optionsIncludingCustom() -> [String] {
        base + [customTag]
    }
}

private enum ScriptDraftError: Error {
    case message(String)
}

private struct ScriptEditDraft {
    var id: Int
    var name: String
    var description: String
    var scriptType: String
    var shell: String
    var argsText: String
    var category: String
    var favorite: Bool
    var defaultTimeout: String
    var syntax: String
    var filename: String
    var hidden: Bool
    var supportedPlatformsText: String
    var runAsUser: Bool
    var envVarsText: String
    var scriptBody: String

    init() {
        id = 0
        name = ""
        description = ""
        scriptType = "userdefined"
        shell = "powershell"
        argsText = ""
        category = ""
        favorite = false
        defaultTimeout = "60"
        syntax = ""
        filename = ""
        hidden = false
        supportedPlatformsText = ""
        runAsUser = false
        envVarsText = ""
        scriptBody = ""
    }

    init(detail: ScriptDetail) {
        id = detail.id
        name = detail.name
        description = detail.description ?? ""
        scriptType = detail.scriptType ?? "userdefined"
        shell = detail.shell
        argsText = detail.args?.joined(separator: "\n") ?? ""
        category = detail.category ?? ""
        favorite = detail.favorite ?? false
        defaultTimeout = detail.defaultTimeout.map { String($0) } ?? ""
        syntax = detail.syntax ?? ""
        filename = detail.filename ?? ""
        hidden = detail.hidden ?? false
        supportedPlatformsText = detail.supportedPlatforms?.joined(separator: "\n") ?? ""
        runAsUser = detail.runAsUser ?? false
        envVarsText = detail.envVars?.compactMap { variable in
            guard let name = variable.name, !name.isEmpty else { return nil }
            if let value = variable.value, !value.isEmpty {
                return "\(name)=\(value)"
            }
            return name
        }.joined(separator: "\n") ?? ""
        scriptBody = detail.scriptBody ?? ""
    }

    func makePayload(existing detail: ScriptDetail) throws -> ScriptUpdatePayload {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ScriptDraftError.message(L10n.key("scripts.error.nameEmpty"))
        }

        let trimmedShell = shell.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedShell.isEmpty else {
            throw ScriptDraftError.message(L10n.key("scripts.error.shellEmpty"))
        }

        let trimmedType = scriptType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedType.isEmpty else {
            throw ScriptDraftError.message(L10n.key("scripts.error.scriptTypeEmpty"))
        }

        let trimmedBody = scriptBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            throw ScriptDraftError.message(L10n.key("scripts.error.scriptBodyEmpty"))
        }

        let timeoutValue: Int
        if defaultTimeout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            timeoutValue = detail.defaultTimeout ?? 60
        } else if let parsed = Int(defaultTimeout.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 {
            timeoutValue = parsed
        } else {
            throw ScriptDraftError.message(L10n.key("scripts.error.timeoutInvalid"))
        }

        let argsArray = argsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let platformsArray = supportedPlatformsText
            .components(separatedBy: .newlines)
            .flatMap { line in
                line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            .filter { !$0.isEmpty }

        let envArray: [ScriptEnvironmentVariablePayload] = envVarsText
            .components(separatedBy: .newlines)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let namePart = parts.first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                guard !namePart.isEmpty else { return nil }
                let valuePart = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
                return ScriptEnvironmentVariablePayload(name: namePart, value: valuePart?.nonEmpty)
            }

        return ScriptUpdatePayload(
            id: id,
            name: trimmedName,
            description: description.nonEmpty,
            scriptType: trimmedType,
            shell: trimmedShell,
            args: argsArray,
            category: category.nonEmpty,
            favorite: favorite,
            defaultTimeout: timeoutValue,
            syntax: syntax.nonEmpty,
            filename: filename.nonEmpty,
            hidden: hidden,
            supportedPlatforms: platformsArray,
            runAsUser: runAsUser,
            envVars: envArray,
            scriptBody: trimmedBody
        )
    }
}

private struct ScriptUpdatePayload: Encodable {
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
    let envVars: [ScriptEnvironmentVariablePayload]
    let scriptBody: String
}

private struct ScriptTestDraft {
    var agentID: String
    var code: String
    var timeout: String
    var argsText: String
    var shell: String
    var runAsUser: Bool
    var envVarsText: String

    init(detail: ScriptDetail) {
        agentID = ""
        code = detail.scriptBody ?? ""
        timeout = detail.defaultTimeout.map { String($0) } ?? "60"
        argsText = detail.args?.joined(separator: "\n") ?? ""
        shell = detail.shell
        runAsUser = detail.runAsUser ?? false
        envVarsText = detail.envVars?.compactMap { variable in
            guard let name = variable.name, !name.isEmpty else { return nil }
            if let value = variable.value, !value.isEmpty {
                return "\(name)=\(value)"
            }
            return name
        }.joined(separator: "\n") ?? ""
    }

    func makePayload() throws -> (String, ScriptTestPayload) {
        let trimmedAgent = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAgent.isEmpty else {
            throw ScriptDraftError.message(L10n.key("scripts.error.agentRequired"))
        }

        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            throw ScriptDraftError.message(L10n.key("scripts.error.scriptCodeEmpty"))
        }

        let trimmedShell = shell.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedShell.isEmpty else {
            throw ScriptDraftError.message(L10n.key("scripts.error.shellEmpty"))
        }

        guard let timeoutValue = Int(timeout.trimmingCharacters(in: .whitespacesAndNewlines)), timeoutValue > 0 else {
            throw ScriptDraftError.message(L10n.key("scripts.error.timeoutInvalid"))
        }

        let argsArray = argsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let envArray: [ScriptEnvironmentVariablePayload] = envVarsText
            .components(separatedBy: .newlines)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let namePart = parts.first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                guard !namePart.isEmpty else { return nil }
                let valuePart = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : nil
                return ScriptEnvironmentVariablePayload(name: namePart, value: valuePart?.nonEmpty)
            }

        let payload = ScriptTestPayload(
            code: trimmedCode,
            timeout: timeoutValue,
            args: argsArray,
            shell: trimmedShell,
            runAsUser: runAsUser,
            envVars: envArray
        )

        return (trimmedAgent, payload)
    }
}

private struct ScriptTestSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    let context: ScriptTestContext
    let agents: [Agent]
    @Binding var isTesting: Bool
    @Binding var result: ScriptTestResponse?
    @Binding var errorMessage: String?
    let onRun: (ScriptTestDraft) async -> Void

    @State private var draft: ScriptTestDraft
    @State private var shellSelection: String
    @State private var customShellText: String

    init(context: ScriptTestContext,
         agents: [Agent],
         isTesting: Binding<Bool>,
         result: Binding<ScriptTestResponse?>,
         errorMessage: Binding<String?>,
         onRun: @escaping (ScriptTestDraft) async -> Void) {
        self.context = context
        self.agents = agents
        _isTesting = isTesting
        _result = result
        _errorMessage = errorMessage
        self.onRun = onRun

        var initialDraft = ScriptTestDraft(detail: context.detail)
        if initialDraft.agentID.isEmpty, let firstAgent = agents.first {
            initialDraft.agentID = firstAgent.agent_id
        }
        let selection = ScriptShellOptions.selection(for: initialDraft.shell)
        if selection.selection != ScriptShellOptions.customTag {
            initialDraft.shell = selection.selection
        }

        _draft = State(initialValue: initialDraft)
        _shellSelection = State(initialValue: selection.selection)
        _customShellText = State(initialValue: selection.custom)
    }

    var body: some View {
        NavigationStack {
            let shellIsValid = shellSelection != ScriptShellOptions.customTag || !customShellText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Form {
                Section {
                    if agents.isEmpty {
                        Text(L10n.key("scripts.test.noAgents"))
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                            .padding(.vertical, 4)
                    } else {
                        Picker(L10n.key("scripts.test.agent"), selection: $draft.agentID) {
                            ForEach(agents) { agent in
                                Text(agentDisplayTitle(for: agent))
                                    .tag(agent.agent_id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } header: {
                    Text(L10n.key("scripts.test.agent"))
                }

                Section {
                    TextField(L10n.key("scripts.test.timeout"), text: $draft.timeout)
                        .keyboardType(.numberPad)
                    Toggle(L10n.key("scripts.test.runAsUser"), isOn: $draft.runAsUser)
                    Picker(L10n.key("scripts.test.shell"), selection: Binding(
                        get: { shellSelection },
                        set: { newValue in
                            shellSelection = newValue
                            if newValue == ScriptShellOptions.customTag {
                                if customShellText.isEmpty {
                                    customShellText = draft.shell
                                }
                            } else {
                                draft.shell = newValue
                                customShellText = ""
                            }
                        }
                    )) {
                        ForEach(ScriptShellOptions.optionsIncludingCustom(), id: \.self) { option in
                            Text(option == ScriptShellOptions.customTag ? L10n.key("scripts.test.shell.custom") : ScriptShellOptions.displayName(for: option))
                                .tag(option)
                        }
                    }
                    .pickerStyle(.menu)

                    if shellSelection == ScriptShellOptions.customTag {
                        TextField(L10n.key("scripts.test.shell.customField"), text: $customShellText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        if customShellText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(L10n.key("scripts.test.shell.customHelp"))
                                .font(.caption2)
                                .foregroundStyle(Color.red)
                        }
                    }
                } header: {
                    Text(L10n.key("scripts.test.execution"))
                }

                Section {
                    TextEditor(text: $draft.argsText)
                        .frame(minHeight: 80)
                } header: {
                    Text(L10n.key("scripts.test.args"))
                } footer: {
                    Text(L10n.key("scripts.test.argsHelp"))
                }

                Section {
                    TextEditor(text: $draft.envVarsText)
                        .frame(minHeight: 80)
                } header: {
                    Text(L10n.key("scripts.test.envVars"))
                } footer: {
                    Text(L10n.key("scripts.test.envVarsHelp"))
                }

                Section {
                    TextEditor(text: $draft.code)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)
                } header: {
                    Text(L10n.key("scripts.test.code"))
                }

                if let result {
                    Section {
                        Text(L10n.format("scripts.test.returnCodeFormat", result.retcode))
                            .font(.caption)
                        if let executionTime = result.executionTime {
                            Text(L10n.format("scripts.test.elapsedFormat", String(format: "%.2fs", executionTime)))
                                .font(.caption)
                        }
                        if !result.stdout.isEmpty {
                            DetailSection(title: L10n.key("scripts.test.stdout")) {
                                Text(result.stdout)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                        if !result.stderr.isEmpty {
                            DetailSection(title: L10n.key("scripts.test.stderr")) {
                                Text(result.stderr)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    } header: {
                        Text(L10n.key("scripts.test.result"))
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.red)
                    }
                }
            }
            .onAppear {
                if draft.agentID.isEmpty, let first = agents.first {
                    draft.agentID = first.agent_id
                } else if !draft.agentID.isEmpty,
                          !agents.contains(where: { $0.agent_id == draft.agentID }),
                          let first = agents.first {
                    draft.agentID = first.agent_id
                }
            }
            .onChange(of: customShellText) { _, newValue in
                if shellSelection == ScriptShellOptions.customTag {
                    draft.shell = newValue
                }
            }
            .navigationTitle(L10n.key("scripts.test.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.key("common.close")) { dismiss() }
                        .foregroundStyle(appTheme.accent)
                        .disabled(isTesting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await onRun(draft) }
                    } label: {
                        if isTesting {
                            ProgressView()
                        } else {
                            Text(L10n.key("common.run"))
                        }
                    }
                    .disabled(isTesting || agents.isEmpty || draft.agentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !shellIsValid)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func agentDisplayTitle(for agent: Agent) -> String {
        if let site = agent.site_name, !site.isEmpty {
            return "\(agent.hostname) - \(site)"
        }
        return agent.hostname
    }
}

private struct ScriptEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    @Binding var draft: ScriptEditDraft
    @Binding var isSaving: Bool
    @Binding var errorMessage: String?
    let onSave: () async -> Void

    @State private var shellSelection: String
    @State private var customShellText: String

    init(draft: Binding<ScriptEditDraft>,
         isSaving: Binding<Bool>,
         errorMessage: Binding<String?>,
         onSave: @escaping () async -> Void) {
        _draft = draft
        _isSaving = isSaving
        _errorMessage = errorMessage
        self.onSave = onSave

        let selection = ScriptShellOptions.selection(for: draft.wrappedValue.shell)
        if selection.selection != ScriptShellOptions.customTag {
            draft.wrappedValue.shell = selection.selection
        }
        _shellSelection = State(initialValue: selection.selection)
        _customShellText = State(initialValue: selection.custom)
    }

    var body: some View {
        let shellIsValid = shellSelection != ScriptShellOptions.customTag || !customShellText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return NavigationStack {
            Form {
                Section {
                    TextField(L10n.key("common.name"), text: $draft.name)
                        .textInputAutocapitalization(.words)
                    TextField(L10n.key("scripts.edit.description"), text: $draft.description, axis: .vertical)
                        .lineLimit(1...4)
                    TextField(L10n.key("scripts.edit.category"), text: $draft.category)
                        .textInputAutocapitalization(.words)
                    Toggle(L10n.key("scripts.edit.favorite"), isOn: $draft.favorite)
                    Toggle(L10n.key("scripts.edit.hidden"), isOn: $draft.hidden)
                } header: {
                    Text(L10n.key("scripts.edit.basics"))
                }

                Section {
                    TextField(L10n.key("scripts.edit.scriptType"), text: $draft.scriptType)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Picker(L10n.key("scripts.test.shell"), selection: Binding(
                        get: { shellSelection },
                        set: { newValue in
                            shellSelection = newValue
                            if newValue == ScriptShellOptions.customTag {
                                if customShellText.isEmpty {
                                    customShellText = draft.shell
                                }
                            } else {
                                draft.shell = newValue
                                customShellText = ""
                            }
                        }
                    )) {
                        ForEach(ScriptShellOptions.optionsIncludingCustom(), id: \.self) { option in
                            Text(option == ScriptShellOptions.customTag ? L10n.key("scripts.test.shell.custom") : ScriptShellOptions.displayName(for: option))
                                .tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    if shellSelection == ScriptShellOptions.customTag {
                        TextField(L10n.key("scripts.test.shell.customField"), text: $customShellText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        if customShellText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(L10n.key("scripts.test.shell.customHelp"))
                                .font(.caption2)
                                .foregroundStyle(Color.red)
                        }
                    }
                    TextField(L10n.key("scripts.test.timeout"), text: $draft.defaultTimeout)
                        .keyboardType(.numberPad)
                    Toggle(L10n.key("scripts.test.runAsUser"), isOn: $draft.runAsUser)
                } header: {
                    Text(L10n.key("scripts.test.execution"))
                }

                Section {
                    TextEditor(text: $draft.argsText)
                        .frame(minHeight: 80)
                } header: {
                    Text(L10n.key("scripts.edit.arguments"))
                } footer: {
                    Text(L10n.key("scripts.test.argsHelp"))
                }

                Section {
                    TextEditor(text: $draft.supportedPlatformsText)
                        .frame(minHeight: 80)
                } header: {
                    Text(L10n.key("scripts.edit.supportedPlatforms"))
                } footer: {
                    Text(L10n.key("scripts.edit.supportedPlatformsHelp"))
                }

                Section {
                    TextEditor(text: $draft.envVarsText)
                        .frame(minHeight: 80)
                } header: {
                    Text(L10n.key("scripts.test.envVars"))
                } footer: {
                    Text(L10n.key("scripts.test.envVarsHelp"))
                }

                Section {
                    TextEditor(text: $draft.scriptBody)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 240)
                } header: {
                    Text(L10n.key("scripts.edit.scriptBody"))
                }

                Section {
                    TextField(L10n.key("scripts.edit.syntax"), text: $draft.syntax, axis: .vertical)
                        .lineLimit(1...4)
                    TextField(L10n.key("scripts.edit.filename"), text: $draft.filename)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                } header: {
                    Text(L10n.key("scripts.edit.metadata"))
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.red)
                    }
                }
            }
            .onChange(of: customShellText) { _, newValue in
                if shellSelection == ScriptShellOptions.customTag {
                    draft.shell = newValue
                }
            }
            .navigationTitle(L10n.key("scripts.edit.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.key("common.cancel")) { dismiss() }
                        .foregroundStyle(appTheme.accent)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await onSave() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(L10n.key("common.save"))
                        }
                    }
                    .disabled(isSaving || !shellIsValid)
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct ScriptMetaRow: View {
    let summary: ScriptSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                iconText("gear", summary.scriptTypeLabel)
                iconText("timer", summary.timeoutLabel)
                if summary.runAsUser == true {
                    iconText("person.fill", L10n.key("scripts.meta.runAsUser"))
                }
            }

            if let platforms = summary.supportedPlatforms, !platforms.isEmpty {
                HStack(spacing: 6) {
                    ForEach(platforms.prefix(6), id: \.self) { platform in
                        Text(platform)
                            .font(.caption2)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
                }
            }
        }
    }
}

private extension ScriptMetaRow {
    func iconText(_ systemName: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemName)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(Color.white.opacity(0.8))
    }
}

private extension ScriptSummary {
    var scriptTypeLabel: String {
        scriptType?.uppercased() ?? L10n.key("scripts.meta.unknown")
    }

    var timeoutLabel: String {
        if let defaultTimeout { return L10n.format("scripts.meta.timeoutFormat", defaultTimeout) }
        return L10n.key("scripts.meta.timeoutDefault")
    }

    var isBuiltIn: Bool {
        scriptType?.lowercased() == "builtin"
    }
}

private struct ScriptDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    let summary: ScriptSummary
    let detail: ScriptDetail?
    let isLoading: Bool
    let errorMessage: String?
    let fetchedAt: Date?
    let isDeleting: Bool
    let isTesting: Bool
    let canTest: Bool
    let isSavingEdit: Bool
    let onRetry: () -> Void
    let onTest: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                DarkGradientBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        SectionHeader(summary.name, subtitle: summary.category ?? L10n.key("scripts.detail.subtitle"), systemImage: "terminal")

                        if let fetchedAt {
                            Text(L10n.format("scripts.detail.lastRefreshedFormat", fetchedAt.formatted(date: .omitted, time: .shortened)))
                                .font(.caption2)
                                .foregroundStyle(Color.white.opacity(0.6))
                        }

                        ScriptMetaRow(summary: summary)

                        if let description = summary.description, !description.isEmpty {
                            Text(description)
                                .font(.footnote)
                                .foregroundStyle(Color.white.opacity(0.75))
                                .padding(.top, 6)
                        }

                        if isLoading {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text(L10n.key("scripts.detail.loadingBody"))
                                    .font(.footnote)
                                    .foregroundStyle(Color.white.opacity(0.7))
                            }
                        } else if let errorMessage {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(errorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(Color.red)
                                Button {
                                    onRetry()
                                } label: {
                                    Label(L10n.key("common.retry"), systemImage: "arrow.clockwise")
                                        .frame(maxWidth: .infinity)
                                }
                                .primaryButton()
                            }
                        } else if let detail {
                            detailContent(summary: summary, detail: detail, canTest: canTest)
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle(summary.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.key("common.done")) { dismiss() }
                        .foregroundStyle(appTheme.accent)
                }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func detailContent(summary: ScriptSummary, detail: ScriptDetail, canTest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let syntax = detail.syntax, !syntax.isEmpty {
                DetailSection(title: L10n.key("scripts.detail.syntax")) {
                    Text(syntax)
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.white.opacity(0.85))
                        .textSelection(.enabled)
                }
            }

            if let args = detail.args, !args.isEmpty {
                DetailSection(title: L10n.key("scripts.edit.arguments")) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(args, id: \.self) { arg in
                            Text(arg)
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.85))
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if let envVars = detail.envVars, !envVars.isEmpty {
                DetailSection(title: L10n.key("scripts.test.envVars")) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(envVars, id: \.self) { variable in
                            Text(variableLabel(variable))
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.85))
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if let body = detail.scriptBody, !body.isEmpty {
                DetailSection(title: L10n.key("scripts.edit.scriptBody")) {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(body)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 320)
                }
            }

            if let filename = detail.filename, !filename.isEmpty {
                DetailSection(title: L10n.key("scripts.edit.filename")) {
                    Text(filename)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.8))
                        .textSelection(.enabled)
                }
            }

            if let hash = detail.scriptHash, !hash.isEmpty {
                DetailSection(title: L10n.key("scripts.detail.hash")) {
                    Text(hash)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Color.white.opacity(0.85))
                        .textSelection(.enabled)
                }
            }

            actionButtons(summary: summary, detail: detail, canTest: canTest)
        }
    }

    @ViewBuilder
    private func actionButtons(summary: ScriptSummary, detail: ScriptDetail, canTest: Bool) -> some View {
        let isBuiltIn = detail.scriptType?.lowercased() == "builtin" || summary.isBuiltIn

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    onTest()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text(L10n.key("scripts.detail.test"))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .secondaryButton()
                .disabled(isTesting || !canTest)

                Button {
                    if !isBuiltIn {
                        onEdit()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.pencil")
                        Text(L10n.key("common.edit"))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .secondaryButton()
                .disabled(isSavingEdit || isBuiltIn)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                        Text(L10n.key("common.delete"))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .secondaryButton()
                .tint(Color.red)
                .disabled(isDeleting || isBuiltIn)
            }

            if isBuiltIn {
                Text(L10n.key("scripts.detail.builtinNoEditDelete"))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.65))
                    .padding(.top, 4)
            }

            if !canTest {
                Text(L10n.key("scripts.detail.testingRequiresAgents"))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.65))
                    .padding(.top, isBuiltIn ? 2 : 4)
            }
        }
    }


    private func variableLabel(_ variable: ScriptEnvironmentVariable) -> String {
        let name = variable.name ?? L10n.key("scripts.detail.variable")
        if let value = variable.value, !value.isEmpty {
            return "\(name): \(value)"
        }
        return name
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.6))
            content
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
        }
    }
}
