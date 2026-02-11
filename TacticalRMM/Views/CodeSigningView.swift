import SwiftUI

struct CodeSigningView: View {
    let settings: RMMSettings
    @Environment(\.appTheme) private var appTheme

    @State private var token: String?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var showToken = false
    @State private var isShowingEditor = false
    @State private var draftToken = ""
    @State private var isSaving = false
    @State private var alertMessage: String?
    @State private var lastFetched: Date?
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var isSigningAll = false
    @State private var signAllMessage: String?

    var body: some View {
        ZStack {
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 18) {
                            SectionHeader(L10n.key("codesigning.title"), subtitle: L10n.key("codesigning.subtitle"), systemImage: "checkmark.seal.fill")

                            headerButtons()

                            if isLoading {
                                ProgressView()
                                    .frame(maxWidth: .infinity, alignment: .center)
                            } else if let loadError {
                                VStack(spacing: 12) {
                                    Text(loadError)
                                        .font(.footnote)
                                        .foregroundStyle(Color.red)
                                    Button {
                                        Task { await loadToken(force: true) }
                                    } label: {
                                        Label(L10n.key("common.retry"), systemImage: "arrow.clockwise")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .primaryButton()
                                }
                            } else if let token, !token.isEmpty {
                                tokenCard(token)
                            } else {
                                Text(L10n.key("codesigning.empty"))
                                    .font(.footnote)
                                    .foregroundStyle(Color.white.opacity(0.7))
                            }
                        }
                    }

                    if let token, !token.isEmpty {
                        signAllSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }
        }
        .navigationTitle(L10n.key("codesigning.title"))
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDismissToolbar()
        .task { await loadToken(force: true) }
        .refreshable { await loadToken(force: true) }
        .settingsPresentation(
            isPresented: $isShowingEditor,
            fullScreen: ProcessInfo.processInfo.isiOSAppOnMac
        ) {
            CodeSigningEditorSheet(
                token: $draftToken,
                isSaving: $isSaving,
                onClose: { isShowingEditor = false },
                onSubmit: { await handleSubmit() }
            )
            .presentationDetents([.medium])
        }
        .alert(L10n.key("common.error"), isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button(L10n.key("common.ok"), role: .cancel) { }
        } message: {
            if let alertMessage {
                Text(alertMessage)
            }
        }
        .confirmationDialog(
            L10n.key("codesigning.delete.title"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.key("codesigning.delete.confirm"), role: .destructive) {
                Task { await deleteToken() }
            }
            Button(L10n.key("common.cancel"), role: .cancel) { }
        } message: {
            Text(L10n.key("codesigning.delete.message"))
        }
    }

    @ViewBuilder
    private func headerButtons() -> some View {
        HStack(spacing: 12) {
            Button {
                showToken.toggle()
            } label: {
                Label(showToken ? L10n.key("codesigning.hideToken") : L10n.key("codesigning.showToken"), systemImage: showToken ? "eye.slash" : "eye")
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, 9)
                    .padding(.horizontal, 16)
                    .background(
                        Capsule().fill(Color.white.opacity(0.08))
                            .overlay(
                                Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white)

            Spacer()

            Button {
                draftToken = token ?? ""
                isShowingEditor = true
            } label: {
                Label(token?.isEmpty == false ? L10n.key("codesigning.editToken") : L10n.key("codesigning.addToken"), systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, 9)
                    .padding(.horizontal, 16)
                    .background(
                        Capsule().fill(appTheme.accent.opacity(0.18))
                            .overlay(
                                Capsule().stroke(appTheme.accent.opacity(0.3), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(appTheme.accent)
        }
    }

    @ViewBuilder
    private func tokenCard(_ token: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(showToken ? token : String(repeating: "\u{2022}", count: max(token.count, 4)))
                .font(.body.monospaced())
                .foregroundStyle(Color.white)
                .textSelection(.enabled)

            if isDeleting {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(Color.red.opacity(0.8))
                    Text(L10n.key("codesigning.deleting"))
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            } else {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label(L10n.key("codesigning.delete.confirm"), systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .padding(.vertical, 9)
                        .padding(.horizontal, 16)
                        .background(
                            Capsule()
                                .fill(Color.red.opacity(0.18))
                                .overlay(
                                    Capsule().stroke(Color.red.opacity(0.3), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.red)
                .disabled(isDeleting)
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

        private var signAllSection: some View {
            GlassCard {
                VStack(alignment: .leading, spacing: 14) {
                    if let signAllMessage {
                        statusBanner(message: signAllMessage, tint: Color.green)
                    }

                    Button {
                        Task { await signAllAgents() }
                    } label: {
                        HStack(spacing: 10) {
                            if isSigningAll {
                                ProgressView()
                                    .tint(Color.white)
                            } else {
                                Image(systemName: "checkmark.seal")
                                    .font(.headline)
                            }
                            Text(isSigningAll ? L10n.key("codesigning.signingAgents") : L10n.key("codesigning.signAll"))
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 18)
                        .background(
                            Capsule()
                                .fill(Color.green.opacity(0.28))
                                .overlay(
                                    Capsule().stroke(Color.green.opacity(0.45), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.white)
                    .disabled(isSigningAll || isDeleting)
                    .opacity((isSigningAll || isDeleting) ? 0.65 : 1)
                }
            }
        }

    private func statusBanner(message: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(tint)
                .font(.title3)
            Text(message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(tint.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func loadToken(force: Bool = false) async {
        guard !isLoading || force else { return }

        if settings.baseURL.isDemoEntry {
            await MainActor.run {
                token = "DEMO-TOKEN-123"
                isLoading = false
                loadError = nil
                lastFetched = Date()
            }
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            await MainActor.run { loadError = L10n.key("codesigning.error.missingApiKey") }
            return
        }

        guard let request = makeRequest(path: "/core/codesign/", method: "GET", apiKey: apiKey) else {
            await MainActor.run { loadError = L10n.key("codesigning.error.invalidBaseUrl") }
            return
        }

        await MainActor.run {
            isLoading = true
            loadError = nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CodeSigningError.unexpected }

            DiagnosticLogger.shared.logHTTPResponse(
                method: "GET",
                url: request.url?.absoluteString ?? "",
                status: http.statusCode,
                data: data
            )

            switch http.statusCode {
            case 200:
                let decoder = JSONDecoder()
                let payload = try decoder.decode(CodeSigningPayload.self, from: data)
                await MainActor.run {
                    token = payload.token
                    loadError = nil
                    lastFetched = Date()
                }
            case 401:
                throw CodeSigningError.message(L10n.key("codesigning.error.invalidApiKey"))
            default:
                throw CodeSigningError.message(L10n.format("codesigning.error.httpLoad", http.statusCode))
            }
        } catch CodeSigningError.message(let message) {
            await MainActor.run { loadError = message }
        } catch {
            if error.isCancelledRequest {
                await MainActor.run { isLoading = false }
                return
            }
            await MainActor.run { loadError = error.localizedDescription }
            DiagnosticLogger.shared.appendError("Failed to load code signing token: \(error.localizedDescription)")
        }

        await MainActor.run { isLoading = false }
    }

    private func handleSubmit() async {
        guard !isSaving else { return }
        await MainActor.run { isSaving = true }

        do {
            try await updateToken()
            await loadToken(force: true)
            await MainActor.run { isShowingEditor = false }
        } catch CodeSigningError.message(let message) {
            await MainActor.run { alertMessage = message }
        } catch {
            await MainActor.run { alertMessage = error.localizedDescription }
            DiagnosticLogger.shared.appendError("Code signing update failed: \(error.localizedDescription)")
        }

        await MainActor.run { isSaving = false }
    }

    private func signAllAgents() async {
        guard !isSigningAll else { return }

        guard let token, !token.isEmpty else {
            await MainActor.run { alertMessage = L10n.key("codesigning.error.missingToken") }
            return
        }

        if settings.baseURL.isDemoEntry {
            await MainActor.run {
                signAllMessage = L10n.key("codesigning.error.demoBulkUnsupported")
            }
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            await MainActor.run { alertMessage = L10n.key("codesigning.error.missingApiKey") }
            return
        }

        guard var request = makeRequest(path: "/core/codesign/", method: "POST", apiKey: apiKey) else {
            await MainActor.run { alertMessage = L10n.key("codesigning.error.invalidBaseUrl") }
            return
        }

        request.httpBody = Data()

        await MainActor.run {
            isSigningAll = true
            signAllMessage = nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CodeSigningError.unexpected }

            DiagnosticLogger.shared.logHTTPResponse(
                method: "POST",
                url: request.url?.absoluteString ?? "",
                status: http.statusCode,
                data: data
            )

            switch http.statusCode {
            case 200, 202, 204:
                let message = cleanedMessage(from: data, fallback: L10n.key("codesigning.status.signAllQueued"))
                await MainActor.run { signAllMessage = message }
            case 401:
                throw CodeSigningError.message(L10n.key("codesigning.error.invalidApiKey"))
            default:
                let fallback = L10n.format("codesigning.error.httpSignAll", http.statusCode)
                let message = cleanedMessage(from: data, fallback: fallback)
                throw CodeSigningError.message(message)
            }
        } catch CodeSigningError.message(let message) {
            await MainActor.run { alertMessage = message }
        } catch {
            await MainActor.run { alertMessage = error.localizedDescription }
            DiagnosticLogger.shared.appendError("Code signing request failed: \(error.localizedDescription)")
        }

        await MainActor.run { isSigningAll = false }
    }

    private func deleteToken() async {
        await MainActor.run { showDeleteConfirmation = false }
        guard !isDeleting else { return }

        if settings.baseURL.isDemoEntry {
            await MainActor.run {
                token = nil
                loadError = nil
                lastFetched = Date()
                showToken = false
                draftToken = ""
                signAllMessage = nil
                alertMessage = nil
            }
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            await MainActor.run { alertMessage = L10n.key("codesigning.error.missingApiKey") }
            return
        }

        guard let request = makeRequest(path: "/core/codesign/", method: "DELETE", apiKey: apiKey) else {
            await MainActor.run { alertMessage = L10n.key("codesigning.error.invalidBaseUrl") }
            return
        }

        await MainActor.run { isDeleting = true }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CodeSigningError.unexpected }

            DiagnosticLogger.shared.logHTTPResponse(
                method: "DELETE",
                url: request.url?.absoluteString ?? "",
                status: http.statusCode,
                data: data
            )

            switch http.statusCode {
            case 200, 202, 204:
                await MainActor.run {
                    token = nil
                    loadError = nil
                    lastFetched = Date()
                    showToken = false
                    draftToken = ""
                    signAllMessage = nil
                    alertMessage = nil
                }
            case 401:
                throw CodeSigningError.message(L10n.key("codesigning.error.invalidApiKey"))
            default:
                let serverMessage = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = (serverMessage?.isEmpty == false) ? serverMessage! : L10n.format("codesigning.error.httpDelete", http.statusCode)
                throw CodeSigningError.message(message)
            }
        } catch CodeSigningError.message(let message) {
            await MainActor.run { alertMessage = message }
        } catch {
            await MainActor.run { alertMessage = error.localizedDescription }
            DiagnosticLogger.shared.appendError("Code signing delete failed: \(error.localizedDescription)")
        }

        await MainActor.run { isDeleting = false }
    }

    private func updateToken() async throws {
        if settings.baseURL.isDemoEntry {
            await MainActor.run { isShowingEditor = false }
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            throw CodeSigningError.message(L10n.key("codesigning.error.missingApiKey"))
        }

        guard var request = makeRequest(path: "/core/codesign/", method: "PATCH", apiKey: apiKey) else {
            throw CodeSigningError.message(L10n.key("codesigning.error.invalidBaseUrl"))
        }

        let cleanedToken = draftToken.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CodeSigningPayload(token: cleanedToken))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CodeSigningError.unexpected }

        DiagnosticLogger.shared.logHTTPResponse(
            method: "PATCH",
            url: request.url?.absoluteString ?? "",
            status: http.statusCode,
            data: data
        )

        switch http.statusCode {
        case 200, 202, 204:
            return
        case 400:
            let rawMessage = String(data: data, encoding: .utf8) ?? L10n.key("codesigning.error.serverRejectedToken")
            let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            throw CodeSigningError.message(trimmed.isEmpty ? L10n.key("codesigning.error.serverRejectedToken") : trimmed)
        case 401:
            throw CodeSigningError.message(L10n.key("codesigning.error.invalidApiKey"))
        default:
            throw CodeSigningError.message(L10n.format("codesigning.error.httpUpdate", http.statusCode))
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

    private func cleanedMessage(from data: Data, fallback: String) -> String {
        guard let raw = String(data: data, encoding: .utf8) else {
            return fallback
        }
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if trimmed.isEmpty {
            return fallback
        }
        // Normalize well-known server messages to localized strings.
        if trimmed == "Agents will be code signed shortly" {
            return L10n.key("codesigning.sucsess")
        }
        return trimmed
    }
}

private enum CodeSigningError: Error {
    case message(String)
    case unexpected
}

private struct CodeSigningPayload: Codable {
    let token: String
}

private struct CodeSigningEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var token: String
    @Binding var isSaving: Bool
    let onClose: () -> Void
    let onSubmit: () async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.key("codesigning.editor.section")) {
                    TextField(L10n.key("codesigning.editor.placeholder"), text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
            }
            .navigationTitle(L10n.key("codesigning.editor.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.key("common.cancel")) {
                        onClose()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await onSubmit() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(L10n.key("common.save"))
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .keyboardDismissToolbar()
        }
    }
}
