import SwiftUI

struct KeyStoreView: View {
    let settings: RMMSettings

    @State private var entries: [KeyStoreEntry] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var showValues = false
    @State private var isShowingEditor = false
    @State private var editorMode: EditorMode = .add
    @State private var draft = KeyStoreDraft()
    @State private var isSaving = false
    @State private var alertMessage: String?
    @State private var entryPendingDelete: KeyStoreEntry?
    @State private var isDeleting = false

    fileprivate enum EditorMode {
        case add
        case edit
    }

    var body: some View {
        ZStack {
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 18) {
                            SectionHeader("Key Store", subtitle: "Secure key/value storage", systemImage: "key.fill")

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
                                        Task { await loadEntries(force: true) }
                                    } label: {
                                        Label("Retry", systemImage: "arrow.clockwise")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .primaryButton()
                                }
                            } else if entries.isEmpty {
                                Text("No keys stored.")
                                    .font(.footnote)
                                    .foregroundStyle(Color.white.opacity(0.7))
                            } else {
                                keyTable()
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }
        }
        .navigationTitle("Key Store")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadEntries(force: true) }
        .refreshable { await loadEntries(force: true) }
        .sheet(isPresented: $isShowingEditor) {
            KeyStoreEditorSheet(
                mode: editorMode,
                draft: $draft,
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
        .confirmationDialog(
            "Delete Key",
            isPresented: Binding(
                get: { entryPendingDelete != nil },
                set: { if !$0 { entryPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = entryPendingDelete {
                    Task { await deleteEntry(entry) }
                }
            }
            Button("Cancel", role: .cancel) { entryPendingDelete = nil }
        } message: {
            Text("This action cannot be undone.")
        }
    }

    @ViewBuilder
    private func headerButtons() -> some View {
        HStack(spacing: 12) {
            Button {
                showValues.toggle()
            } label: {
                Label(showValues ? "Hide Values" : "Show Values", systemImage: showValues ? "eye.slash" : "eye")
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
                editorMode = .add
                draft = KeyStoreDraft()
                isShowingEditor = true
            } label: {
                Label("Add Key", systemImage: "plus")
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
    private func keyTable() -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Value")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.06))

            ForEach(entries) { entry in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name)
                            .font(.callout)
                            .foregroundStyle(Color.white)
                        Text("by \(entry.createdBy)")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(showValues ? entry.value : String(repeating: "\u{2022}", count: max(entry.value.count, 4)))
                        .font(.callout.monospaced())
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        Button {
                            editorMode = .edit
                            draft = KeyStoreDraft(entry: entry)
                            isShowingEditor = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.cyan)

                        Button {
                            entryPendingDelete = entry
                        } label: {
                            Image(systemName: "trash")
                                .font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.03))
                .overlay(
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 1)
                        .padding(.top, 52)
                        .opacity(entries.last?.id == entry.id ? 0 : 1), alignment: .bottom
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func loadEntries(force: Bool = false) async {
        guard !isLoading || force else { return }

        if settings.baseURL.isDemoEntry {
            await MainActor.run {
                entries = KeyStoreEntry.demoEntries
                isLoading = false
                loadError = nil
            }
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            await MainActor.run {
                loadError = "Missing API key for this instance."
            }
            return
        }

        guard let request = makeRequest(path: "/core/keystore/", method: "GET", apiKey: apiKey) else {
            await MainActor.run {
                loadError = "Invalid base URL."
            }
            return
        }

        await MainActor.run {
            isLoading = true
            loadError = nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw KeyStoreError.unexpected }

            DiagnosticLogger.shared.logHTTPResponse(
                method: "GET",
                url: request.url?.absoluteString ?? "",
                status: http.statusCode,
                data: data
            )

            switch http.statusCode {
            case 200:
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let decoded = try decoder.decode([KeyStoreEntry].self, from: data)
                await MainActor.run {
                    entries = decoded
                    loadError = nil
                }
            case 401:
                throw KeyStoreError.message("Invalid API key or insufficient permissions.")
            default:
                throw KeyStoreError.message("HTTP \(http.statusCode) while loading keystore.")
            }
        } catch KeyStoreError.message(let message) {
            await MainActor.run { loadError = message }
        } catch {
            await MainActor.run { loadError = error.localizedDescription }
            DiagnosticLogger.shared.appendError("Failed to load keystore: \(error.localizedDescription)")
        }

        await MainActor.run { isLoading = false }
    }

    private func handleSubmit() async {
        guard !isSaving else { return }
        await MainActor.run { isSaving = true }

        do {
            switch editorMode {
            case .add:
                try await createEntry()
            case .edit:
                try await updateEntry()
            }
            await loadEntries(force: true)
            await MainActor.run { isShowingEditor = false }
        } catch KeyStoreError.message(let message) {
            await MainActor.run { alertMessage = message }
        } catch {
            await MainActor.run { alertMessage = error.localizedDescription }
            DiagnosticLogger.shared.appendError("Key store save failed: \(error.localizedDescription)")
        }

        await MainActor.run { isSaving = false }
    }

    private func createEntry() async throws {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeyStoreError.message("Name cannot be empty.")
        }
        guard !draft.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeyStoreError.message("Value cannot be empty.")
        }

        try await sendMutatingRequest(method: "POST", body: draft.encodePayload(), pathSuffix: nil)
    }

    private func updateEntry() async throws {
        guard let entry = draft.entry else { return }

        try await sendMutatingRequest(method: "PUT", body: draft.encodeFullPayload(), pathSuffix: "\(entry.id)/")
    }

    private func deleteEntry(_ entry: KeyStoreEntry) async {
        guard !isDeleting else { return }
        guard !settings.baseURL.isDemoEntry else {
            await MainActor.run {
                entries.removeAll { $0.id == entry.id }
                entryPendingDelete = nil
            }
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            await MainActor.run { alertMessage = "Missing API key for this instance." }
            return
        }

        guard let request = makeRequest(path: "/core/keystore/\(entry.id)/", method: "DELETE", apiKey: apiKey) else {
            await MainActor.run { alertMessage = "Invalid base URL." }
            return
        }

        await MainActor.run { isDeleting = true }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw KeyStoreError.unexpected }

            switch http.statusCode {
            case 200, 202, 204:
                await loadEntries(force: true)
            case 401:
                throw KeyStoreError.message("Invalid API key or insufficient permissions.")
            default:
                throw KeyStoreError.message("HTTP \(http.statusCode) while deleting key.")
            }
        } catch KeyStoreError.message(let message) {
            await MainActor.run { alertMessage = message }
        } catch {
            await MainActor.run { alertMessage = error.localizedDescription }
            DiagnosticLogger.shared.appendError("Failed to delete key: \(error.localizedDescription)")
        }

        await MainActor.run {
            isDeleting = false
            entryPendingDelete = nil
        }
    }

    private func sendMutatingRequest(method: String, body: Data, pathSuffix: String?) async throws {
        if settings.baseURL.isDemoEntry {
            await MainActor.run { isShowingEditor = false }
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            throw KeyStoreError.message("Missing API key for this instance.")
        }

        guard var request = makeRequest(path: "/core/keystore/" + (pathSuffix ?? ""), method: method, apiKey: apiKey) else {
            throw KeyStoreError.message("Invalid base URL.")
        }

        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw KeyStoreError.unexpected }

        DiagnosticLogger.shared.logHTTPResponse(
            method: method,
            url: request.url?.absoluteString ?? "",
            status: http.statusCode,
            data: data
        )

        switch http.statusCode {
        case 200, 201, 202, 204:
            return
        case 400:
            throw KeyStoreError.message("Server rejected the request.")
        case 401:
            throw KeyStoreError.message("Invalid API key or insufficient permissions.")
        default:
            throw KeyStoreError.message("HTTP \(http.statusCode) while updating keystore.")
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

private enum KeyStoreError: Error {
    case message(String)
    case unexpected
}

private struct KeyStoreEntry: Identifiable, Codable, Equatable {
    let id: Int
    let createdBy: String
    let createdTime: Date
    let modifiedBy: String
    let modifiedTime: Date
    let name: String
    let value: String

    static let demoEntries: [KeyStoreEntry] = [
        KeyStoreEntry(
            id: 1,
            createdBy: "Demo",
            createdTime: Date(),
            modifiedBy: "Demo",
            modifiedTime: Date(),
            name: "DemoKey",
            value: "DemoValue"
        )
    ]
}

private struct KeyStoreDraft {
    var entry: KeyStoreEntry?
    var name: String
    var value: String

    init(entry: KeyStoreEntry? = nil) {
        self.entry = entry
        self.name = entry?.name ?? ""
        self.value = entry?.value ?? ""
    }

    func encodePayload() throws -> Data {
        let payload = KeyStoreMutationPayload(name: name, value: value)
        return try JSONEncoder().encode(payload)
    }

    func encodeFullPayload() throws -> Data {
        guard let entry else { return try encodePayload() }
        let payload = KeyStoreFullPayload(
            name: name,
            value: value,
            id: entry.id,
            createdBy: entry.createdBy,
            createdTime: entry.createdTime,
            modifiedBy: entry.modifiedBy,
            modifiedTime: entry.modifiedTime
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(payload)
    }
}

private struct KeyStoreMutationPayload: Encodable {
    let name: String
    let value: String
}

private struct KeyStoreFullPayload: Encodable {
    let name: String
    let value: String
    let id: Int
    let createdBy: String
    let createdTime: Date
    let modifiedBy: String
    let modifiedTime: Date
}

private struct KeyStoreEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mode: KeyStoreView.EditorMode
    @Binding var draft: KeyStoreDraft
    @Binding var isSaving: Bool
    let onSubmit: () async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Key Details") {
                    TextField("Name", text: $draft.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField("Value", text: $draft.value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
            }
            .navigationTitle(mode == .add ? "Add Key" : "Edit Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        draft = KeyStoreDraft(entry: draft.entry)
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
