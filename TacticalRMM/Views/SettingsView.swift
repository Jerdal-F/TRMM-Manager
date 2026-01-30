import SwiftUI
import SwiftData
import LocalAuthentication

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appTheme) private var appTheme
    @Query private var settingsList: [RMMSettings]

    @AppStorage("useFaceID") var useFaceID: Bool = false
    @AppStorage("hideSensitive") var hideSensitiveInfo: Bool = false
    @AppStorage("activeSettingsUUID") private var activeSettingsUUID: String = ""
    @AppStorage("selectedTheme") private var selectedThemeID: String = AppTheme.default.rawValue
    @AppStorage("lastSeenDateFormat") private var lastSeenDateFormat: String = ""
    @AppStorage("selectedBackground") private var selectedBackgroundID: String = AppBackgroundStyle.default.rawValue

    @State private var showResetConfirmation = false
    @State private var showAddInstanceSheet = false
    @State private var newInstanceName: String = ""
    @State private var newInstanceURL: String = ""
    @State private var newInstanceKey: String = ""
    @State private var addInstanceError: String?
    @State private var showAddInstanceAlert = false
    @State private var addInstanceAlertTitle: String = ""
    @State private var addInstanceAlertMessage: String = ""
    @FocusState private var addInstanceField: AddInstanceField?
    @State private var editingInstance: RMMSettings?
    @State private var editInstanceName: String = ""
    @State private var editInstanceURL: String = ""
    @State private var editInstanceKey: String = ""
    @State private var editInstanceError: String?
    @FocusState private var editInstanceField: EditInstanceField?
    @State private var showDonationSheet = false
    @State private var showReleaseNotes = false
    @State private var pendingDeleteInstance: RMMSettings?

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
        if settingsList.isEmpty { return L10n.key("settings.instances.subtitle.none") }
        if let active = activeSettings { return L10n.format("settings.instances.subtitle.active", active.displayName) }
        return L10n.key("settings.instances.subtitle.select")
    }

    private var selectedTheme: AppTheme {
        AppTheme(rawValue: selectedThemeID) ?? .default
    }

    private var selectedBackground: AppBackgroundStyle {
        AppBackgroundStyle(rawValue: selectedBackgroundID) ?? .default
    }

    private struct TimestampFormatChoice: Identifiable {
        let id: String
        let title: String
        let storedValue: String
        let detail: String
    }

    private var sanitizedLastSeenFormat: String {
        lastSeenDateFormat.replacingOccurrences(of: "\n", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var timestampFormatChoices: [TimestampFormatChoice] {
        let devicePattern = DateConstants.devicePreferredLastSeenFormat()
        return [
            TimestampFormatChoice(id: "device", title: L10n.key("settings.timestamp.choice.device"), storedValue: "", detail: devicePattern),
            TimestampFormatChoice(id: "fallback", title: L10n.key("settings.timestamp.choice.fallback"), storedValue: DateConstants.fallbackLastSeenFormat, detail: DateConstants.fallbackLastSeenFormat),
            TimestampFormatChoice(id: "us12", title: L10n.key("settings.timestamp.choice.us12"), storedValue: "hh:mm a MM/dd/yyyy", detail: "HH:MM a MM/dd/yyyy")
        ]
    }
    
    private var selectedTimestampFormatChoice: TimestampFormatChoice {
        let sanitized = sanitizedLastSeenFormat
        if sanitized.isEmpty {
            return timestampFormatChoices.first(where: { $0.id == "device" }) ?? timestampFormatChoices[0]
        }
        return timestampFormatChoices.first(where: { $0.storedValue == sanitized }) ?? timestampFormatChoices.first(where: { $0.id == "device" }) ?? timestampFormatChoices[0]
    }

    private var lastSeenPreviewText: String {
        previewString(for: selectedTimestampFormatChoice.storedValue)
    }

    private func previewString(for storedValue: String) -> String {
        let sampleISO = DateConstants.lastSeenISOFormatter.string(from: Date())
        return formatLastSeenTimestamp(sampleISO, customFormat: storedValue)
    }

    private func backgroundGradient(for style: AppBackgroundStyle) -> LinearGradient {
        LinearGradient(
            colors: style.gradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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
            .navigationTitle(L10n.key("settings.title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.key("common.done")) { dismiss() }
                        .foregroundStyle(appTheme.accent)
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
            .sheet(isPresented: $showReleaseNotes) {
                ReleaseNotesView()
            }
            .alert(L10n.key("settings.alert.deleteAllTitle"), isPresented: $showResetConfirmation) {
                Button(L10n.key("common.delete"), role: .destructive) {
                    NotificationCenter.default.post(name: .init("clearAppData"), object: nil)
                    dismiss()
                }
                Button(L10n.key("common.cancel"), role: .cancel) {}
            } message: {
                Text(L10n.key("settings.alert.deleteAllMessage"))
            }
            .alert(L10n.key("settings.alert.deleteInstanceTitle"), isPresented: Binding(
                get: { pendingDeleteInstance != nil },
                set: { if !$0 { pendingDeleteInstance = nil } }
            )) {
                Button(L10n.key("common.delete"), role: .destructive) {
                    if let instance = pendingDeleteInstance {
                        deleteInstance(instance)
                    }
                    pendingDeleteInstance = nil
                }
                Button(L10n.key("common.cancel"), role: .cancel) {
                    pendingDeleteInstance = nil
                }
            } message: {
                if let instance = pendingDeleteInstance {
                    Text(L10n.format("settings.alert.deleteInstanceMessage", instance.displayName))
                }
            }
        }
    }

    private var instancesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(L10n.key("settings.instances.title"), subtitle: instanceSubtitle, systemImage: "server.rack")

                if settingsList.isEmpty {
                    Text(L10n.key("settings.instances.empty"))
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
                    Label(L10n.key("settings.instances.add"), systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .primaryButton()
            }
        }
    }

    private var preferencesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(L10n.key("settings.preferences.title"), subtitle: L10n.key("settings.preferences.subtitle"), systemImage: "gearshape")

                settingsToggle(title: L10n.key("settings.hideSensitive"), isOn: $hideSensitiveInfo)

                Toggle(isOn: $useFaceID) {
                    Text(L10n.key("settings.faceIDLock"))
                        .font(.callout)
                        .foregroundStyle(Color.white)
                }
                .toggleStyle(SwitchToggleStyle(tint: appTheme.accent))
                .disabled(!authAvailable)
                .opacity(authAvailable ? 1 : 0.4)

                if !authAvailable {
                    Text(L10n.key("settings.faceIDRequirement"))
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.6))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.key("settings.theme.title"))
                        .font(.callout)
                        .foregroundStyle(Color.white)

                    Menu {
                        ForEach(AppTheme.allCases) { theme in
                            Button {
                                selectedThemeID = theme.rawValue
                            } label: {
                                if theme == selectedTheme {
                                    Label(theme.displayName, systemImage: "checkmark")
                                } else {
                                    Text(theme.displayName)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(selectedTheme.accent)
                                .frame(width: 18, height: 18)
                                .shadow(color: selectedTheme.accent.opacity(0.45), radius: 6, x: 0, y: 3)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(selectedTheme.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.white)
                                Text(L10n.key("settings.theme.detail"))
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.6))
                            }

                            Spacer(minLength: 0)

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.footnote)
                                .foregroundStyle(Color.white.opacity(0.7))
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
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.key("settings.background.title"))
                        .font(.callout)
                        .foregroundStyle(Color.white)

                    Menu {
                        ForEach(AppBackgroundStyle.allCases) { style in
                            Button {
                                selectedBackgroundID = style.rawValue
                            } label: {
                                let isSelected = style == selectedBackground
                                HStack(spacing: 12) {
                                    backgroundGradient(for: style)
                                        .frame(width: 40, height: 24)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                                        )
                                    Text(style.displayName)
                                    if isSelected {
                                        Spacer(minLength: 0)
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            backgroundGradient(for: selectedBackground)
                                .frame(width: 46, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.white.opacity(0.35), lineWidth: 1)
                                )

                            VStack(alignment: .leading, spacing: 4) {
                                Text(selectedBackground.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.white)
                                Text(L10n.key("settings.background.detail"))
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.6))
                            }

                            Spacer(minLength: 0)

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.footnote)
                                .foregroundStyle(Color.white.opacity(0.7))
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
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.key("settings.timestamp.title"))
                        .font(.callout)
                        .foregroundStyle(Color.white)

                    Menu {
                        ForEach(timestampFormatChoices) { choice in
                            Button {
                                lastSeenDateFormat = choice.storedValue
                            } label: {
                                let isSelected = choice.id == selectedTimestampFormatChoice.id
                                HStack(alignment: .center, spacing: 12) {
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(choice.title)
                                        Text(previewString(for: choice.storedValue))
                                            .font(.caption2)
                                            .foregroundStyle(Color.white.opacity(0.6))
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(selectedTimestampFormatChoice.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.white)
                                Text(lastSeenPreviewText)
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.6))
                            }

                            Spacer(minLength: 0)

                            Image(systemName: "chevron.up.chevron.down")
                                .font(.footnote)
                                .foregroundStyle(Color.white.opacity(0.7))
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
                    .buttonStyle(.plain)

                }
                .onAppear {
                    let sanitized = sanitizedLastSeenFormat
                    if sanitized != lastSeenDateFormat {
                        lastSeenDateFormat = sanitized
                    }
                }
                .onChange(of: lastSeenDateFormat) { _, newValue in
                    let sanitized = newValue.replacingOccurrences(of: "\n", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if sanitized != newValue {
                        lastSeenDateFormat = sanitized
                    }
                }
            }
        }
    }

    private var resourcesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(L10n.key("settings.resources.title"), subtitle: L10n.key("settings.resources.subtitle"), systemImage: "book")

                Button {
                    if let url = URL(string: "https://trmm-manager.jerdal.no") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label(L10n.key("settings.resources.guide"), systemImage: "globe")
                        .frame(maxWidth: .infinity)
                }
                .secondaryButton()

                Button {
                    showReleaseNotes = true
                } label: {
                    Label(L10n.key("settings.resources.whatsNew"), systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .secondaryButton()

                Button {
                    showDonationSheet = true
                } label: {
                    Label(L10n.key("settings.resources.donation"), systemImage: "heart.fill")
                        .frame(maxWidth: .infinity)
                }
                .secondaryButton()
            }
        }
    }

    private var dangerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(L10n.key("settings.danger.title"), subtitle: L10n.key("settings.danger.subtitle"), systemImage: "exclamationmark.triangle")

                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label(L10n.key("settings.danger.deleteData"), systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .buttonBorderShape(.roundedRectangle(radius: 14))
            }
        }
    }

    private var footer: some View {
        Text(L10n.key("settings.footer"))
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
                        Text(L10n.key("settings.instances.activeBadge"))
                            .font(.caption2.weight(.bold))
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(appTheme.accent.opacity(0.2))
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
                    Button {
                        setActiveInstance(resolved, triggerReload: true)
                    } label: {
                        Label(L10n.key("settings.instances.setActive"), systemImage: "checkmark.circle")
                    }
                }

                Button(L10n.key("common.edit"), systemImage: "pencil") {
                    beginEditing(resolved)
                }

                if settingsList.count > 1 {
                    Button(role: .destructive) {
                        pendingDeleteInstance = resolved
                    } label: {
                        Label(L10n.key("settings.instances.delete"), systemImage: "trash")
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
                        .stroke(isActive ? appTheme.accent.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1)
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
                        SectionHeader(L10n.key("settings.add.title"), subtitle: L10n.key("settings.add.subtitle"), systemImage: "server.rack")

                        inputField(title: L10n.key("settings.field.displayName"), placeholder: L10n.key("settings.placeholder.serverName"), text: $newInstanceName)
                            .focused($addInstanceField, equals: .name)

                        inputField(title: L10n.key("settings.field.baseURL"), placeholder: L10n.key("settings.placeholder.exampleURL"), text: $newInstanceURL)
                            .platformKeyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .focused($addInstanceField, equals: .url)

                        inputField(title: L10n.key("settings.field.apiKey"), placeholder: L10n.key("settings.placeholder.apiKey"), text: $newInstanceKey, isSecure: true)
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
            .navigationTitle(L10n.key("settings.add.navigationTitle", comment: "Add instance navigation title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.key("common.cancel")) { showAddInstanceSheet = false }
                        .foregroundStyle(appTheme.accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.key("common.save")) { createInstance() }
                        .foregroundStyle(appTheme.accent)
                        .disabled(newInstanceName.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  newInstanceURL.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  newInstanceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                addInstanceField = .name
            }
            .alert(addInstanceAlertTitle, isPresented: $showAddInstanceAlert) {
                Button(L10n.key("common.ok"), role: .cancel) {
                    DispatchQueue.main.async {
                        addInstanceField = .url
                    }
                }
            } message: {
                Text(addInstanceAlertMessage)
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
                        SectionHeader(L10n.key("settings.edit.title"), subtitle: settings.displayName, systemImage: "pencil" )

                        inputField(title: L10n.key("settings.field.displayName"), placeholder: settings.displayName, text: $editInstanceName)
                            .focused($editInstanceField, equals: .name)

                        inputField(title: L10n.key("settings.field.baseURL"), placeholder: L10n.key("settings.placeholder.exampleURL"), text: $editInstanceURL)
                            .platformKeyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .focused($editInstanceField, equals: .url)

                        inputField(title: L10n.key("settings.field.apiKey"), placeholder: L10n.key("settings.placeholder.apiKey"), text: $editInstanceKey, isSecure: true)
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
            .navigationTitle(L10n.key("settings.edit.navigationTitle", comment: "Edit instance navigation title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.key("common.cancel")) { cancelEditInstance() }
                        .foregroundStyle(appTheme.accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.key("common.save")) { saveEditedInstance() }
                        .foregroundStyle(appTheme.accent)
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
        .toggleStyle(SwitchToggleStyle(tint: appTheme.accent))
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
            addInstanceError = L10n.key("settings.validation.displayName")
            addInstanceField = .name
            return
        }
        guard !trimmedURL.isEmpty else {
            addInstanceError = L10n.key("settings.validation.baseURL")
            addInstanceField = .url
            return
        }
        let lowerURL = trimmedURL.lowercased()
        if lowerURL.contains("http://") {
            addInstanceError = nil
            addInstanceAlertTitle = L10n.key("settings.add.alert.secureTitle")
            addInstanceAlertMessage = L10n.key("settings.add.alert.secureMessage")
            addInstanceField = nil
            UIApplication.shared.dismissKeyboard()
            showAddInstanceAlert = true
            return
        }
        guard !trimmedKey.isEmpty else {
            addInstanceError = L10n.key("settings.validation.apiKey")
            addInstanceField = .key
            return
        }

        let normalizedURL = normalizeBaseURL(trimmedURL)
        if !trimmedURL.isDemoEntry {
            guard let components = URLComponents(string: normalizedURL), let host = components.host, host.isValidDomainName else {
                addInstanceError = nil
                addInstanceAlertTitle = L10n.key("settings.add.alert.invalidDomainTitle")
                addInstanceAlertMessage = L10n.key("settings.add.alert.invalidDomainMessage")
                addInstanceField = nil
                UIApplication.shared.dismissKeyboard()
                showAddInstanceAlert = true
                return
            }
        }
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
            addInstanceError = L10n.format("common.failedToSaveFormat", error.localizedDescription)
        }
    }

    private func normalizeBaseURL(_ raw: String) -> String {
        let lower = raw.lowercased()
        if raw.isDemoEntry { return "demo" }
        if lower.hasPrefix("http://") {
            let suffix = String(raw.dropFirst("http://".count))
            return "https://" + suffix
        }
        if lower.hasPrefix("https://") {
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
            editInstanceError = L10n.key("settings.validation.displayName")
            editInstanceField = .name
            return
        }
        guard !trimmedURL.isEmpty else {
            editInstanceError = L10n.key("settings.validation.baseURL")
            editInstanceField = .url
            return
        }
        guard !trimmedKey.isEmpty else {
            editInstanceError = L10n.key("settings.validation.apiKey")
            editInstanceField = .key
            return
        }

        let normalizedURL = normalizeBaseURL(trimmedURL)
        if !trimmedURL.isDemoEntry {
            guard let components = URLComponents(string: normalizedURL), let host = components.host, host.isValidDomainName else {
                editInstanceError = L10n.key("settings.validation.invalidDomain")
                editInstanceField = .url
                return
            }
        }
        let cleanedURL = normalizedURL.removingTrailingSlash()
        let resolved = ensureIdentifiers(for: instance)
        resolved.displayName = trimmedName
        resolved.baseURL = cleanedURL
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
            editInstanceError = L10n.format("common.failedToSaveFormat", error.localizedDescription)
        }
    }
}
