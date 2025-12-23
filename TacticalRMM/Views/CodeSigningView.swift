import SwiftUI

struct CodeSigningView: View {
    let settings: RMMSettings

    @State private var token: String?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var showToken = false
    @State private var isShowingEditor = false
    @State private var draftToken = ""
    @State private var isSaving = false
    @State private var alertMessage: String?
    @State private var lastFetched: Date?

    var body: some View {
        ZStack {
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 18) {
                            SectionHeader("Code Signing", subtitle: "Manage your Tactical RMM code signing token", systemImage: "checkmark.seal.fill")

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
                                        Label("Retry", systemImage: "arrow.clockwise")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .primaryButton()
                                }
                            } else if let token, !token.isEmpty {
                                tokenCard(token)
                            } else {
                                Text("No code signing token stored yet.")
                                    .font(.footnote)
                                    .foregroundStyle(Color.white.opacity(0.7))
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }
        }
        .navigationTitle("Code Signing")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadToken(force: true) }
        .refreshable { await loadToken(force: true) }
        .sheet(isPresented: $isShowingEditor) {
            CodeSigningEditorSheet(
                token: $draftToken,
                isSaving: $isSaving,
                onSubmit: { await handleSubmit() }
            )
            .presentationDetents([.medium])
        }
        .alert("Error", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            if let alertMessage {
                Text(alertMessage)
            }
        }
    }

    @ViewBuilder
    private func headerButtons() -> some View {
        HStack(spacing: 12) {
            Button {
                showToken.toggle()
            } label: {
                Label(showToken ? "Hide Token" : "Show Token", systemImage: showToken ? "eye.slash" : "eye")
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
                Label(token?.isEmpty == false ? "Edit Token" : "Add Token", systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, 9)
                    .padding(.horizontal, 16)
                    .background(
                        Capsule().fill(Color.cyan.opacity(0.18))
                            .overlay(
                                Capsule().stroke(Color.cyan.opacity(0.3), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.cyan)
        }
    }

    @ViewBuilder
    private func tokenCard(_ token: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(showToken ? token : String(repeating: "\u{2022}", count: max(token.count, 4)))
                .font(.body.monospaced())
                .foregroundStyle(Color.white)
                .textSelection(.enabled)

            if let lastFetched {
                Text("Last fetched: \(lastFetched.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.5))
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
            await MainActor.run { loadError = "Missing API key for this instance." }
            return
        }

        guard let request = makeRequest(path: "/core/codesign/", method: "GET", apiKey: apiKey) else {
            await MainActor.run { loadError = "Invalid base URL." }
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
                throw CodeSigningError.message("Invalid API key or insufficient permissions.")
            default:
                throw CodeSigningError.message("HTTP \(http.statusCode) while loading code signing token.")
            }
        } catch CodeSigningError.message(let message) {
            await MainActor.run { loadError = message }
        } catch {
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

    private func updateToken() async throws {
        if settings.baseURL.isDemoEntry {
            await MainActor.run { isShowingEditor = false }
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            throw CodeSigningError.message("Missing API key for this instance.")
        }

        guard var request = makeRequest(path: "/core/codesign/", method: "PATCH", apiKey: apiKey) else {
            throw CodeSigningError.message("Invalid base URL.")
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
            let rawMessage = String(data: data, encoding: .utf8) ?? "Server rejected the token."
            let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            throw CodeSigningError.message(trimmed.isEmpty ? "Server rejected the token." : trimmed)
        case 401:
            throw CodeSigningError.message("Invalid API key or insufficient permissions.")
        default:
            throw CodeSigningError.message("HTTP \(http.statusCode) while updating token.")
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
    let onSubmit: () async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Token") {
                    TextField("Enter token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
            }
            .navigationTitle("Code Signing Token")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
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
                            Text("Save")
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }
}
