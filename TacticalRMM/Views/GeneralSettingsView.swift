import SwiftUI

struct GeneralSettingsView: View {
    enum Mode {
        case general
        case email
        case sms
    }

    let settings: RMMSettings
    @Environment(\.appTheme) private var appTheme
    let mode: Mode

    init(settings: RMMSettings, mode: Mode = .general) {
        self.settings = settings
        self.mode = mode
    }

    @State private var form = GeneralSettingsForm()
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var loadErrorMessage: String?
    @State private var saveErrorMessage: String?
    @State private var statusMessage: String?
    @State private var allTimezones: [String] = []
    @State private var serverPolicyOptions: [GeneralOption] = []
    @State private var workstationPolicyOptions: [GeneralOption] = []
    @State private var alertTemplateOptions: [GeneralOption] = []
    @State private var isResettingPatchPolicy = false
    @State private var lastResponse: GeneralSettingsResponse?
    @State private var newEmailRecipient = ""
    @State private var newSMSRecipient = ""
    @FocusState private var isEmailRecipientFieldFocused: Bool
    @FocusState private var isSMSRecipientFieldFocused: Bool

    private let dateFormats = [
        "DD-MM-YYYY - HH:mm",
        "YYYY-MM-DD HH:mm",
        "MM/DD/YYYY HH:mm",
        "DD/MM/YYYY HH:mm",
        "YYYY-MM-DD - HH:mm"
    ]

    private let debugLevels = [
        "debug",
        "info",
        "warning",
        "error",
        "critical"
    ]

    var body: some View {
        ZStack {
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 18) {
                            if let header = headerContent() {
                                SectionHeader(header.title, subtitle: header.subtitle, systemImage: header.icon)
                            }

                            if isLoading {
                                HStack {
                                    ProgressView()
                                    Text("Loading settings…")
                                        .font(.footnote)
                                        .foregroundStyle(Color.white.opacity(0.7))
                                }
                            } else if let loadErrorMessage {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(loadErrorMessage)
                                        .font(.footnote)
                                        .foregroundStyle(Color.red)
                                    Button {
                                        Task { await loadSettings(force: true) }
                                    } label: {
                                        Label("Retry", systemImage: "arrow.clockwise")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .primaryButton()
                                }
                            } else {
                                contentForCurrentMode()
                            }
                        }
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.green)
                    }

                    if let saveErrorMessage {
                        Text(saveErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.red)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }
        }
        .navigationTitle(navigationTitle())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await saveSettings() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .foregroundStyle(appTheme.accent)
                .disabled(isLoading || isSaving)
            }
        }
        .task {
            await loadSettings(force: true)
        }
        .refreshable {
            await loadSettings(force: true)
        }
    }

    private func headerContent() -> (title: String, subtitle: String, icon: String)? {
        switch mode {
        case .general:
            return ("General", "Core server configuration", "gearshape")
        case .email:
            return nil
        case .sms:
            return nil
        }
    }

    private func navigationTitle() -> String {
        switch mode {
        case .general:
            return "General Settings"
        case .email:
            return "Email Settings"
        case .sms:
            return "SMS Settings"
        }
    }

    @ViewBuilder
    private func contentForCurrentMode() -> some View {
        switch mode {
        case .general:
            generalSettingsSection()
        case .email:
            emailAlertsSection(includeHeader: false)
        case .sms:
            smsAlertsSection()
        }
    }

    @ViewBuilder
    private func generalSettingsSection() -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle(isOn: $form.agentAutoUpdate) {
                Text("Enable agent automatic self update")
                    .font(.callout)
                    .foregroundStyle(Color.white)
            }
            .toggleStyle(SwitchToggleStyle(tint: appTheme.accent))

            Toggle(isOn: $form.enableServerScripts) {
                Text("Enable server side scripts")
                    .font(.callout)
                    .foregroundStyle(Color.white)
            }
            .toggleStyle(SwitchToggleStyle(tint: appTheme.accent))

            Toggle(isOn: $form.enableServerWebterminal) {
                Text("Enable web terminal")
                    .font(.callout)
                    .foregroundStyle(Color.white)
            }
            .toggleStyle(SwitchToggleStyle(tint: appTheme.accent))

            separator()

            selectionMenu(
                title: "Default agent timezone",
                current: form.defaultTimeZone.isEmpty ? "Not set" : form.defaultTimeZone,
                options: allTimezones,
                onSelect: { form.defaultTimeZone = $0 }
            )
            .disabled(allTimezones.isEmpty)

            selectionMenu(
                title: "Default date format",
                current: form.dateFormat.isEmpty ? "Not set" : form.dateFormat,
                options: effectiveDateFormats,
                onSelect: { form.dateFormat = $0 }
            )

            selectionMenu(
                title: "Agent debug level",
                current: form.agentDebugLevel,
                options: debugLevels,
                onSelect: { form.agentDebugLevel = $0 }
            )

            separator()

            policyPicker(
                title: "Default server policy",
                options: serverPolicyOptions,
                selected: $form.serverPolicy
            )

            policyPicker(
                title: "Default workstation policy",
                options: workstationPolicyOptions,
                selected: $form.workstationPolicy
            )

            policyPicker(
                title: "Default alert template",
                options: alertTemplateOptions,
                selected: $form.alertTemplate
            )

            separator()

            VStack(alignment: .leading, spacing: 6) {
                Text("Clear faults on agents that haven't checked in after (days)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .kerning(1.1)
                TextField("20", text: $form.clearFaultsDays)
                    .platformKeyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
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

            separator()

            Toggle(isOn: $form.notifyOnInfoAlerts) {
                Text("Receive informational alert notifications")
                    .font(.callout)
                    .foregroundStyle(Color.white)
            }
            .toggleStyle(SwitchToggleStyle(tint: appTheme.accent))

            Toggle(isOn: $form.notifyOnWarningAlerts) {
                Text("Receive warning alert notifications")
                    .font(.callout)
                    .foregroundStyle(Color.white)
            }
            .toggleStyle(SwitchToggleStyle(tint: appTheme.accent))

            separator()

            Button {
                Task { await resetPatchPolicies() }
            } label: {
                if isResettingPatchPolicy {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Reset Patch Policy on Agents", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.red.opacity(0.85))
            .disabled(isResettingPatchPolicy || isLoading || isSaving)
        }
    }

    private var effectiveDateFormats: [String] {
        if form.dateFormat.isEmpty { return dateFormats }
        if dateFormats.contains(form.dateFormat) { return dateFormats }
        return [form.dateFormat] + dateFormats
    }

    @ViewBuilder
    private func emailAlertsSection(includeHeader: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if includeHeader {
                SectionHeader("Email Alerts", subtitle: "Routing & SMTP", systemImage: "envelope")
            }

            SectionHeader("Email Alert Routing", subtitle: "Recipients", systemImage: "envelope.badge")

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Recipients")

                if form.emailRecipients.isEmpty {
                    Text("No recipients added yet.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.6))
                } else {
                    VStack(spacing: 10) {
                        ForEach(form.emailRecipients, id: \.self) { recipient in
                            HStack {
                                Text(recipient)
                                    .font(.callout)
                                    .foregroundStyle(Color.white)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    removeEmailRecipient(recipient)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.callout.weight(.semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.red)
                                .accessibilityLabel("Remove \(recipient)")
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
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

                HStack(spacing: 12) {
                    TextField("user@example.com", text: $newEmailRecipient)
                        .platformKeyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.done)
                        .focused($isEmailRecipientFieldFocused)
                        .onSubmit { addEmailRecipient() }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        )

                    Button {
                        addEmailRecipient()
                    } label: {
                        Label("Add", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .padding(.vertical, 10)
                            .padding(.horizontal, 18)
                            .background(
                                Capsule().fill(appTheme.accent.opacity(0.18))
                                    .overlay(
                                        Capsule().stroke(appTheme.accent.opacity(0.3), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appTheme.accent)
                    .disabled(newEmailRecipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            separator()

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("SMTP Settings", subtitle: "Outbound email configuration", systemImage: "paperplane")

                groupedTextField(
                    title: "From email:",
                    text: $form.smtpFromEmail,
                    placeholder: "notify@example.com",
                    keyboard: .emailAddress
                )

                groupedTextField(
                    title: "From name:",
                    text: $form.smtpFromName,
                    placeholder: "Tactical RMM"
                )

                groupedTextField(
                    title: "Host:",
                    text: $form.smtpHost,
                    placeholder: "mail.smtp2go.com"
                )

                groupedTextField(
                    title: "Port:",
                    text: $form.smtpPort,
                    placeholder: "2525",
                    keyboard: .numberPad
                )

                Toggle(isOn: $form.smtpRequiresAuth) {
                    Text("My Server Requires Authentication")
                        .font(.callout)
                        .foregroundStyle(Color.white)
                }
                .toggleStyle(SwitchToggleStyle(tint: appTheme.accent))

                groupedTextField(
                    title: "Username:",
                    text: $form.smtpUsername,
                    placeholder: "notify@example.com",
                    keyboard: .emailAddress,
                    disabled: !form.smtpRequiresAuth
                )

                groupedSecureField(
                    title: "Password:",
                    text: $form.smtpPassword,
                    placeholder: "Password",
                    disabled: !form.smtpRequiresAuth
                )
            }
        }
    }

    @ViewBuilder
    private func smsAlertsSection() -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader("SMS Alert Routing", subtitle: "Recipients", systemImage: "bubble.left.and.bubble.right")

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Recipients")

                if form.smsRecipients.isEmpty {
                    Text("No recipients added yet.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.6))
                } else {
                    VStack(spacing: 10) {
                        ForEach(form.smsRecipients, id: \.self) { recipient in
                            HStack {
                                Text(recipient)
                                    .font(.callout)
                                    .foregroundStyle(Color.white)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    removeSMSRecipient(recipient)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.callout.weight(.semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.red)
                                .accessibilityLabel("Remove \(recipient)")
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
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

                HStack(spacing: 12) {
                    TextField("+1234567890", text: $newSMSRecipient)
                        .platformKeyboardType(.phonePad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.done)
                        .focused($isSMSRecipientFieldFocused)
                        .onSubmit { addSMSRecipient() }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        )

                    Button {
                        addSMSRecipient()
                    } label: {
                        Label("Add", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .padding(.vertical, 10)
                            .padding(.horizontal, 18)
                            .background(
                                Capsule().fill(appTheme.accent.opacity(0.18))
                                    .overlay(
                                        Capsule().stroke(appTheme.accent.opacity(0.3), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appTheme.accent)
                    .disabled(newSMSRecipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            separator()

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Twilio Settings", subtitle: "SMS delivery provider", systemImage: "dot.radiowaves.left.and.right")

                groupedTextField(
                    title: "Twilio Number:",
                    text: $form.twilioNumber,
                    placeholder: "+1234567890",
                    keyboard: .phonePad
                )

                groupedTextField(
                    title: "Twilio Account SID:",
                    text: $form.twilioAccountSid,
                    placeholder: "ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
                )

                groupedTextField(
                    title: "Twilio Auth Token:",
                    text: $form.twilioAuthToken,
                    placeholder: "Auth token"
                )
            }
        }
    }

    @ViewBuilder
    private func separator() -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private func groupedTextField(title: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType? = nil, disabled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(title)
            buildTextField(placeholder: placeholder, text: text, keyboard: keyboard)
                .disabled(disabled)
        }
    }

    private func buildTextField(placeholder: String, text: Binding<String>, keyboard: UIKeyboardType?) -> some View {
        Group {
            if let keyboard {
                TextField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .platformKeyboardType(keyboard)
            } else {
                TextField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func groupedSecureField(title: String, text: Binding<String>, placeholder: String, disabled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(title)
            SecureField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
                .disabled(disabled)
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.6))
            .kerning(1.1)
    }

    private func addEmailRecipient() {
        let trimmed = newEmailRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !form.emailRecipients.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            form.emailRecipients.append(trimmed)
        }

        newEmailRecipient = ""
        isEmailRecipientFieldFocused = true
    }

    private func removeEmailRecipient(_ recipient: String) {
        form.emailRecipients.removeAll { $0.caseInsensitiveCompare(recipient) == .orderedSame }
    }

    private func addSMSRecipient() {
        let trimmed = newSMSRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !form.smsRecipients.contains(where: { $0 == trimmed }) {
            form.smsRecipients.append(trimmed)
        }

        newSMSRecipient = ""
        isSMSRecipientFieldFocused = true
    }

    private func removeSMSRecipient(_ recipient: String) {
        let normalizedTarget = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        form.smsRecipients.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedTarget }
    }

    @ViewBuilder
    private func selectionMenu(title: String, current: String, options: [String], onSelect: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.6))
                .kerning(1.1)

            Menu {
                Picker(title, selection: Binding(
                    get: { current },
                    set: { newValue in onSelect(newValue) }
                )) {
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
            } label: {
                HStack {
                    Text(current)
                        .font(.callout)
                        .foregroundStyle(Color.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appTheme.accent)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
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

    @ViewBuilder
    private func policyPicker(title: String, options: [GeneralOption], selected: Binding<GeneralOption?>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.6))
                .kerning(1.1)

            Menu {
                ForEach(options) { option in
                    Button(option.name) {
                        selected.wrappedValue = option
                    }
                }
            } label: {
                HStack {
                    Text(selected.wrappedValue?.name ?? options.first?.name ?? "Not set")
                        .font(.callout)
                        .foregroundStyle(Color.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appTheme.accent)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
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

    private func loadSettings(force: Bool = false) async {
        guard !isLoading || force else { return }

        if settings.baseURL.isDemoEntry {
            await loadDemoSettings()
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            await MainActor.run {
                loadErrorMessage = "Missing API key for this instance."
                isLoading = false
            }
            return
        }

        let base = settings.baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(base)/core/settings/") else {
            await MainActor.run {
                loadErrorMessage = "Invalid base URL."
                isLoading = false
            }
            return
        }

        await MainActor.run {
            isLoading = true
            loadErrorMessage = nil
            statusMessage = nil
        }

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
                await MainActor.run {
                    loadErrorMessage = "Unexpected response."
                }
                DiagnosticLogger.shared.appendError("General settings response missing HTTPURLResponse.")
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
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                do {
                    let decoded = try decoder.decode(GeneralSettingsResponse.self, from: data)
                    await MainActor.run {
                        apply(response: decoded)
                    }
                } catch {
                    await MainActor.run {
                        loadErrorMessage = "Failed to decode settings."
                    }
                    DiagnosticLogger.shared.appendError("Failed to decode general settings: \(error.localizedDescription)")
                }
            case 401:
                await MainActor.run {
                    loadErrorMessage = "Invalid API key or insufficient permissions."
                }
            case 403:
                await MainActor.run {
                    loadErrorMessage = "You do not have permission to view settings."
                }
            default:
                await MainActor.run {
                    loadErrorMessage = "HTTP \(http.statusCode) while loading settings."
                }
            }
        } catch {
            await MainActor.run {
                loadErrorMessage = error.localizedDescription
            }
            DiagnosticLogger.shared.appendError("Failed to load general settings: \(error.localizedDescription)")
        }

        await MainActor.run {
            isLoading = false
        }
    }

    private func saveSettings() async {
        guard !isSaving else { return }

        if settings.baseURL.isDemoEntry {
            await MainActor.run {
                statusMessage = "Settings updated (demo)."
                saveErrorMessage = nil
            }
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            await MainActor.run {
                saveErrorMessage = "Missing API key for this instance."
            }
            return
        }

        guard form.settingsID != nil else {
            await MainActor.run {
                saveErrorMessage = "Settings not loaded yet."
            }
            return
        }

        let trimmedClearFaults = form.clearFaultsDays.trimmingCharacters(in: .whitespacesAndNewlines)
        let clearFaultsValue = Int(trimmedClearFaults) ?? form.clearFaultsFallback

        guard let fullPayload = buildFullPayload(clearFaultsDays: clearFaultsValue) else {
            await MainActor.run {
                saveErrorMessage = "Failed to encode request."
            }
            return
        }

        let base = settings.baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(base)/core/settings/") else {
            await MainActor.run {
                saveErrorMessage = "Invalid base URL."
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 45
        request.addDefaultHeaders(apiKey: apiKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = fullPayload

        DiagnosticLogger.shared.logHTTPRequest(
            method: "PUT",
            url: url.absoluteString,
            headers: request.allHTTPHeaderFields ?? [:]
        )

        await MainActor.run {
            isSaving = true
            saveErrorMessage = nil
            statusMessage = nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                await MainActor.run {
                    saveErrorMessage = "Unexpected response."
                }
                DiagnosticLogger.shared.appendError("General settings save missing HTTPURLResponse.")
                return
            }

            DiagnosticLogger.shared.logHTTPResponse(
                method: "PUT",
                url: url.absoluteString,
                status: http.statusCode,
                data: data
            )

            switch http.statusCode {
            case 200, 202, 204:
                await loadSettings(force: true)
                await MainActor.run {
                    statusMessage = "Settings updated successfully."
                    saveErrorMessage = nil
                }
            case 400:
                await MainActor.run {
                    saveErrorMessage = "Server rejected the update."
                }
            case 401:
                await MainActor.run {
                    saveErrorMessage = "Invalid API key or insufficient permissions."
                }
            case 403:
                await MainActor.run {
                    saveErrorMessage = "You do not have permission to update settings."
                }
            default:
                await MainActor.run {
                    saveErrorMessage = "HTTP \(http.statusCode) while saving settings."
                }
            }
        } catch {
            await MainActor.run {
                saveErrorMessage = error.localizedDescription
            }
            DiagnosticLogger.shared.appendError("Failed to save general settings: \(error.localizedDescription)")
        }

        await MainActor.run {
            isSaving = false
        }
    }

    private func resetPatchPolicies() async {
        guard !isResettingPatchPolicy else { return }

        if settings.baseURL.isDemoEntry {
            await MainActor.run {
                statusMessage = "Patch policies reset (demo)."
            }
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            await MainActor.run {
                statusMessage = nil
                saveErrorMessage = "Missing API key for this instance."
            }
            return
        }

        let base = settings.baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(base)/core/settings/reset_patch_policy/") else {
            await MainActor.run {
                statusMessage = nil
                saveErrorMessage = "Invalid base URL."
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.addDefaultHeaders(apiKey: apiKey)

        DiagnosticLogger.shared.logHTTPRequest(
            method: "POST",
            url: url.absoluteString,
            headers: request.allHTTPHeaderFields ?? [:]
        )

        await MainActor.run {
            isResettingPatchPolicy = true
            statusMessage = nil
            saveErrorMessage = nil
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                await MainActor.run {
                    saveErrorMessage = "Unexpected response while resetting patch policy."
                }
                DiagnosticLogger.shared.appendError("Reset patch policy response missing HTTPURLResponse.")
                return
            }

            DiagnosticLogger.shared.logHTTPResponse(
                method: "POST",
                url: url.absoluteString,
                status: http.statusCode,
                data: Data()
            )

            switch http.statusCode {
            case 200, 202, 204:
                await MainActor.run {
                    statusMessage = "Patch policies reset successfully."
                }
            case 401:
                await MainActor.run {
                    saveErrorMessage = "Invalid API key or insufficient permissions."
                }
            case 403:
                await MainActor.run {
                    saveErrorMessage = "You do not have permission to reset patch policies."
                }
            default:
                await MainActor.run {
                    saveErrorMessage = "HTTP \(http.statusCode) while resetting patch policy."
                }
            }
        } catch {
            await MainActor.run {
                saveErrorMessage = error.localizedDescription
            }
            DiagnosticLogger.shared.appendError("Failed to reset patch policy: \(error.localizedDescription)")
        }

        await MainActor.run {
            isResettingPatchPolicy = false
        }
    }

    @MainActor
    private func apply(response: GeneralSettingsResponse) {
        lastResponse = response
        allTimezones = response.allTimezones
        serverPolicyOptions = []
        workstationPolicyOptions = []
        alertTemplateOptions = []

        let serverOption = option(for: response.serverPolicy, in: &serverPolicyOptions, placeholder: "No policy")
        let workstationOption = option(for: response.workstationPolicy, in: &workstationPolicyOptions, placeholder: "No policy")
        let alertOption = option(for: response.alertTemplate, in: &alertTemplateOptions, placeholder: "No alert template")

        form = GeneralSettingsForm(
            settingsID: response.id,
            agentAutoUpdate: response.agentAutoUpdate,
            enableServerScripts: response.enableServerScripts,
            enableServerWebterminal: response.enableServerWebterminal,
            defaultTimeZone: response.defaultTimeZone ?? "",
            dateFormat: response.dateFormat ?? "",
            emailRecipients: response.emailAlertRecipients ?? [],
            smsRecipients: response.smsAlertRecipients ?? [],
            smtpFromEmail: response.smtpFromEmail ?? "",
            smtpFromName: response.smtpFromName ?? "",
            smtpHost: response.smtpHost ?? "",
            smtpPort: response.smtpPort.map { String($0) } ?? "",
            smtpRequiresAuth: response.smtpRequiresAuth ?? false,
            smtpUsername: response.smtpHostUser ?? "",
            smtpPassword: response.smtpHostPassword ?? "",
            twilioNumber: response.twilioNumber ?? "",
            twilioAccountSid: response.twilioAccountSid ?? "",
            twilioAuthToken: response.twilioAuthToken ?? "",
            serverPolicy: serverOption,
            workstationPolicy: workstationOption,
            alertTemplate: alertOption,
            notifyOnInfoAlerts: response.notifyOnInfoAlerts,
            notifyOnWarningAlerts: response.notifyOnWarningAlerts,
            agentDebugLevel: response.agentDebugLevel,
            clearFaultsDays: response.clearFaultsDays.map { String($0) } ?? "",
            clearFaultsFallback: response.clearFaultsDays ?? 20
        )
        newEmailRecipient = ""
        newSMSRecipient = ""
    }

    @MainActor
    private func option(for rawID: Int?, in storage: inout [GeneralOption], placeholder: String) -> GeneralOption? {
        if storage.first(where: { $0.rawID == nil }) == nil {
            storage.insert(GeneralOption(rawID: nil, name: placeholder), at: 0)
        }

        guard let rawID else {
            return storage.first(where: { $0.rawID == nil })
        }

        if let existing = storage.first(where: { $0.rawID == rawID }) {
            return existing
        }

        let newOption = GeneralOption(rawID: rawID, name: "ID #\(rawID)")
        storage.append(newOption)
        return newOption
    }

    private func buildFullPayload(clearFaultsDays: Int) -> Data? {
        guard let lastResponse else { return nil }

        let normalizedTimeZone = form.defaultTimeZone.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDateFormat = form.dateFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRecipients = form.emailRecipients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedSMSRecipients = form.smsRecipients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedFromEmail = form.smtpFromEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFromName = form.smtpFromName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = form.smtpHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = form.smtpUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPassword = form.smtpPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTwilioNumber = form.twilioNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTwilioAccountSid = form.twilioAccountSid.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTwilioAuthToken = form.twilioAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)

        let portString = form.smtpPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let smtpPortValue: Int?
        if portString.isEmpty {
            smtpPortValue = nil
        } else if let parsed = Int(portString) {
            smtpPortValue = parsed
        } else {
            smtpPortValue = lastResponse.smtpPort
        }

        let smtpUsernameValue = form.smtpRequiresAuth ? (normalizedUsername.isEmpty ? nil : normalizedUsername) : nil
        let smtpPasswordValue: String?
        if form.smtpRequiresAuth {
            if normalizedPassword.isEmpty {
                smtpPasswordValue = lastResponse.smtpHostPassword
            } else {
                smtpPasswordValue = normalizedPassword
            }
        } else {
            smtpPasswordValue = nil
        }

        let payload = GeneralSettingsUpdatePayload(
            id: lastResponse.id,
            email_alert_recipients: normalizedRecipients,
            sms_alert_recipients: normalizedSMSRecipients,
            twilio_number: normalizedTwilioNumber.isEmpty ? nil : normalizedTwilioNumber,
            twilio_account_sid: normalizedTwilioAccountSid.isEmpty ? nil : normalizedTwilioAccountSid,
            twilio_auth_token: normalizedTwilioAuthToken.isEmpty ? nil : normalizedTwilioAuthToken,
            smtp_from_email: normalizedFromEmail.isEmpty ? nil : normalizedFromEmail,
            smtp_from_name: normalizedFromName.isEmpty ? nil : normalizedFromName,
            smtp_host: normalizedHost.isEmpty ? nil : normalizedHost,
            smtp_host_user: smtpUsernameValue,
            smtp_host_password: smtpPasswordValue,
            smtp_port: smtpPortValue,
            smtp_requires_auth: form.smtpRequiresAuth,
            default_time_zone: normalizedTimeZone.isEmpty ? nil : normalizedTimeZone,
            check_history_prune_days: lastResponse.checkHistoryPruneDays,
            resolved_alerts_prune_days: lastResponse.resolvedAlertsPruneDays,
            agent_history_prune_days: lastResponse.agentHistoryPruneDays,
            debug_log_prune_days: lastResponse.debugLogPruneDays,
            audit_log_prune_days: lastResponse.auditLogPruneDays,
            report_history_prune_days: lastResponse.reportHistoryPruneDays,
            agent_debug_level: form.agentDebugLevel,
            clear_faults_days: clearFaultsDays,
            mesh_token: lastResponse.meshToken,
            mesh_username: lastResponse.meshUsername,
            mesh_site: lastResponse.meshSite,
            mesh_device_group: lastResponse.meshDeviceGroup,
            mesh_company_name: lastResponse.meshCompanyName,
            sync_mesh_with_trmm: lastResponse.syncMeshWithTrmm,
            agent_auto_update: form.agentAutoUpdate,
            date_format: normalizedDateFormat.isEmpty ? nil : normalizedDateFormat,
            open_ai_token: lastResponse.openAiToken,
            open_ai_model: lastResponse.openAiModel,
            enable_server_scripts: form.enableServerScripts,
            enable_server_webterminal: form.enableServerWebterminal,
            notify_on_info_alerts: form.notifyOnInfoAlerts,
            notify_on_warning_alerts: form.notifyOnWarningAlerts,
            block_local_user_logon: lastResponse.blockLocalUserLogon,
            sso_enabled: lastResponse.ssoEnabled,
            workstation_policy: form.workstationPolicy?.rawID,
            server_policy: form.serverPolicy?.rawID,
            alert_template: form.alertTemplate?.rawID
        )

        let encoder = JSONEncoder()
        do {
            return try encoder.encode(payload)
        } catch {
            DiagnosticLogger.shared.appendError("Failed to encode general settings payload: \(error.localizedDescription)")
            return nil
        }
    }

    @MainActor
    private func loadDemoSettings() async {
        lastResponse = nil
        form = GeneralSettingsForm(
            settingsID: 1,
            agentAutoUpdate: true,
            enableServerScripts: true,
            enableServerWebterminal: true,
            defaultTimeZone: "Europe/Oslo",
            dateFormat: "DD-MM-YYYY - HH:mm",
            emailRecipients: ["demo@example.com"],
            smsRecipients: ["+47000000000"],
            smtpFromEmail: "smtp@example.com",
            smtpFromName: "Tactical RMM",
            smtpHost: "mail.smtp2go.com",
            smtpPort: "2525",
            smtpRequiresAuth: true,
            smtpUsername: "notify@example.com",
            smtpPassword: "smtp-password",
            twilioNumber: "+46000000000",
            twilioAccountSid: "XXXXXXXXXXXXXXXXXX",
            twilioAuthToken: "XXXXXXXXXXXXXXXXXX",
            serverPolicy: GeneralOption(rawID: nil, name: "No policy"),
            workstationPolicy: GeneralOption(rawID: nil, name: "No policy"),
            alertTemplate: GeneralOption(rawID: nil, name: "No alert template"),
            notifyOnInfoAlerts: false,
            notifyOnWarningAlerts: true,
            agentDebugLevel: "warning",
            clearFaultsDays: "20",
            clearFaultsFallback: 20
        )
        allTimezones = TimeZone.knownTimeZoneIdentifiers
        serverPolicyOptions = [GeneralOption(rawID: nil, name: "No policy")]
        workstationPolicyOptions = [GeneralOption(rawID: nil, name: "No policy")]
        alertTemplateOptions = [GeneralOption(rawID: nil, name: "No alert template")]
        loadErrorMessage = nil
        statusMessage = nil
        newEmailRecipient = ""
        newSMSRecipient = ""
    }
}

private struct GeneralOption: Identifiable, Hashable {
    let rawID: Int?
    let name: String

    var id: String { rawID.map(String.init) ?? "none" }
}

private struct GeneralSettingsForm {
    var settingsID: Int? = nil
    var agentAutoUpdate: Bool = false
    var enableServerScripts: Bool = false
    var enableServerWebterminal: Bool = false
    var defaultTimeZone: String = ""
    var dateFormat: String = ""
    var emailRecipients: [String] = []
    var smsRecipients: [String] = []
    var smtpFromEmail: String = ""
    var smtpFromName: String = ""
    var smtpHost: String = ""
    var smtpPort: String = ""
    var smtpRequiresAuth: Bool = false
    var smtpUsername: String = ""
    var smtpPassword: String = ""
    var twilioNumber: String = ""
    var twilioAccountSid: String = ""
    var twilioAuthToken: String = ""
    var serverPolicy: GeneralOption? = GeneralOption(rawID: nil, name: "No policy")
    var workstationPolicy: GeneralOption? = GeneralOption(rawID: nil, name: "No policy")
    var alertTemplate: GeneralOption? = GeneralOption(rawID: nil, name: "No alert template")
    var notifyOnInfoAlerts: Bool = false
    var notifyOnWarningAlerts: Bool = true
    var agentDebugLevel: String = "warning"
    var clearFaultsDays: String = ""
    var clearFaultsFallback: Int = 20
}

private struct GeneralSettingsResponse: Decodable {
    let id: Int
    let allTimezones: [String]
    let emailAlertRecipients: [String]?
    let smsAlertRecipients: [String]?
    let twilioNumber: String?
    let twilioAccountSid: String?
    let twilioAuthToken: String?
    let smtpFromEmail: String?
    let smtpFromName: String?
    let smtpHost: String?
    let smtpHostUser: String?
    let smtpHostPassword: String?
    let smtpPort: Int?
    let smtpRequiresAuth: Bool?
    let defaultTimeZone: String?
    let checkHistoryPruneDays: Int?
    let resolvedAlertsPruneDays: Int?
    let agentHistoryPruneDays: Int?
    let debugLogPruneDays: Int?
    let auditLogPruneDays: Int?
    let reportHistoryPruneDays: Int?
    let agentAutoUpdate: Bool
    let dateFormat: String?
    let agentDebugLevel: String
    let clearFaultsDays: Int?
    let meshToken: String?
    let meshUsername: String?
    let meshSite: String?
    let meshDeviceGroup: String?
    let meshCompanyName: String?
    let syncMeshWithTrmm: Bool
    let openAiToken: String?
    let openAiModel: String?
    let enableServerScripts: Bool
    let enableServerWebterminal: Bool
    let notifyOnInfoAlerts: Bool
    let notifyOnWarningAlerts: Bool
    let blockLocalUserLogon: Bool
    let ssoEnabled: Bool
    let workstationPolicy: Int?
    let serverPolicy: Int?
    let alertTemplate: Int?
}

private struct GeneralSettingsUpdatePayload: Encodable {
    let id: Int
    let email_alert_recipients: [String]
    let sms_alert_recipients: [String]
    let twilio_number: String?
    let twilio_account_sid: String?
    let twilio_auth_token: String?
    let smtp_from_email: String?
    let smtp_from_name: String?
    let smtp_host: String?
    let smtp_host_user: String?
    let smtp_host_password: String?
    let smtp_port: Int?
    let smtp_requires_auth: Bool
    let default_time_zone: String?
    let check_history_prune_days: Int?
    let resolved_alerts_prune_days: Int?
    let agent_history_prune_days: Int?
    let debug_log_prune_days: Int?
    let audit_log_prune_days: Int?
    let report_history_prune_days: Int?
    let agent_debug_level: String
    let clear_faults_days: Int
    let mesh_token: String?
    let mesh_username: String?
    let mesh_site: String?
    let mesh_device_group: String?
    let mesh_company_name: String?
    let sync_mesh_with_trmm: Bool
    let agent_auto_update: Bool
    let date_format: String?
    let open_ai_token: String?
    let open_ai_model: String?
    let enable_server_scripts: Bool
    let enable_server_webterminal: Bool
    let notify_on_info_alerts: Bool
    let notify_on_warning_alerts: Bool
    let block_local_user_logon: Bool
    let sso_enabled: Bool
    let workstation_policy: Int?
    let server_policy: Int?
    let alert_template: Int?
}
