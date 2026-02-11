import SwiftUI

struct UserAdministrationView: View {
    let settings: RMMSettings
    @Environment(\.appTheme) private var appTheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("lastSeenDateFormat") private var lastSeenDateFormat: String = ""

    @State private var users: [RMMUser] = []
    @State private var roles: [Int: RMMRole] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var roleErrorMessage: String?
    @State private var editingUser: RMMUser?
    @State private var editUsername: String = ""
    @State private var editFirstName: String = ""
    @State private var editLastName: String = ""
    @State private var editEmail: String = ""
    @State private var editRoleID: Int?
    @State private var editRoleText: String = ""
    @State private var editRoleName: String = ""
    @State private var roleSelectionVersion = UUID()
    @State private var rolesVersion = 0
    @State private var editIsActive = false
    @State private var editBlockDashboard = false
    @State private var editErrorMessage: String?
    @State private var isSavingUser = false
    @State private var resettingUser: RMMUser?
    @State private var resetPassword: String = ""
    @State private var resetErrorMessage: String?
    @State private var isResettingPassword = false
    @State private var reset2FAMessage: String?
    @State private var reset2FAIsError = false
    @State private var showReset2FAOverlay = false
    @State private var sessionUser: RMMUser?
    @State private var userSessions: [UserSession] = []
    @State private var isLoadingSessions = false
    @State private var sessionsErrorMessage: String?
    @State private var deletingSessionDigests: Set<String> = []
    @State private var isLoggingOutAllSessions = false

    var body: some View {
        ZStack {
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    if let reset2FAMessage, !showReset2FAOverlay {
                        reset2FABanner(message: reset2FAMessage, isError: reset2FAIsError)
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 18) {
                            SectionHeader(L10n.key("users.section.title"), subtitle: L10n.key("users.section.subtitle"), systemImage: "person.3.fill")

                            if isLoading && users.isEmpty {
                                HStack {
                                    ProgressView()
                                    Text("Loading users…")
                                        .font(.footnote)
                                        .foregroundStyle(Color.white.opacity(0.7))
                                }
                            } else if let errorMessage {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(errorMessage)
                                        .font(.footnote)
                                        .foregroundStyle(Color.red)
                                    Button {
                                        Task { await loadInitialData(force: true) }
                                    } label: {
                                        Label("Retry", systemImage: "arrow.clockwise")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .primaryButton()
                                }
                            } else if users.isEmpty {
                                Text("No users found.")
                                    .font(.footnote)
                                    .foregroundStyle(Color.white.opacity(0.7))
                            } else {
                                LazyVStack(spacing: 14) {
                                    ForEach(users) { user in
                                        userRow(for: user)
                                    }
                                }
                            }

                            if let roleErrorMessage {
                                Text(roleErrorMessage)
                                    .font(.caption2)
                                    .foregroundStyle(Color.yellow.opacity(0.9))
                            }
                        }
                    }

                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }
        }
        .overlay {
            if let message = reset2FAMessage, showReset2FAOverlay {
                reset2FAOverlay(message: message, isError: reset2FAIsError)
            }
        }
        .navigationTitle("User Administration")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDismissToolbar()
        .task(id: settings.uuid) {
            await loadInitialData(force: true)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await loadInitialData(force: true) }
        }
        .refreshable {
            await loadInitialData(force: true)
        }
        .settingsPresentation(item: $editingUser, fullScreen: ProcessInfo.processInfo.isiOSAppOnMac) { user in
            editUserSheet(for: user, onClose: { editingUser = nil })
        }
        .sheet(item: $resettingUser) { user in
            resetPasswordSheet(for: user)
        }
        .sheet(item: $sessionUser) { user in
            activeSessionsSheet(for: user)
        }
    }

    private func beginEditingUser(_ user: RMMUser) {
        editUsername = user.username
        editFirstName = user.firstName ?? ""
        editLastName = user.lastName ?? ""
        editEmail = user.email ?? ""
        syncEditRoleState(with: user)
        roleSelectionVersion = UUID()
        editIsActive = user.isActive
        editBlockDashboard = user.blockDashboardLogin ?? false
        editErrorMessage = nil
        isSavingUser = false
        editingUser = user
    }

    private func cancelEditingUser() {
        editingUser = nil
        editUsername = ""
        editFirstName = ""
        editLastName = ""
        editEmail = ""
        editRoleID = nil
        editRoleText = ""
        editRoleName = ""
        editIsActive = false
        editBlockDashboard = false
        editErrorMessage = nil
        isSavingUser = false
    }

    private func refreshEditRoleName() {
        let fallbackID = editRoleID ?? editingUser?.role ?? roles.values.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }.first?.id
        guard let roleID = fallbackID else {
            editRoleName = ""
            return
        }
        editRoleName = selectedRoleName(for: roleID)
    }

    private func syncEditRoleState(with user: RMMUser) {
        editRoleID = user.role
        editRoleText = user.role.map { String($0) } ?? ""
        editRoleName = user.role.map { selectedRoleName(for: $0) } ?? ""
    }

    private func beginResettingPassword(_ user: RMMUser) {
        resetPassword = ""
        resetErrorMessage = nil
        isResettingPassword = false
        resettingUser = user
    }

    private func cancelResettingPassword() {
        resettingUser = nil
        resetPassword = ""
        resetErrorMessage = nil
        isResettingPassword = false
    }

    private func beginViewingSessions(_ user: RMMUser) {
        resetSessionState()
        sessionUser = user
    }

    private func resetSessionState() {
        userSessions = []
        sessionsErrorMessage = nil
        deletingSessionDigests = []
        isLoadingSessions = false
        isLoggingOutAllSessions = false
    }

    @ViewBuilder
    private func editUserSheet(for user: RMMUser, onClose: @escaping () -> Void) -> some View {
        NavigationStack {
            ZStack {
                DarkGradientBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        SectionHeader(L10n.key("users.edit.title"), subtitle: user.displayName, systemImage: "pencil")

                        editInput(title: L10n.key("users.field.username"), text: $editUsername)

                        editInput(title: L10n.key("users.field.firstName"), text: $editFirstName, capitalization: .words)

                        editInput(title: L10n.key("users.field.lastName"), text: $editLastName, capitalization: .words)

                        editInput(title: L10n.key("users.field.email"), text: $editEmail, keyboard: .emailAddress)

                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $editIsActive) {
                                Text(L10n.key("users.toggle.activeUser"))
                                    .font(.callout)
                                    .foregroundStyle(Color.white)
                            }
                            .toggleStyle(SwitchToggleStyle(tint: appTheme.accent))

                            Toggle(isOn: $editBlockDashboard) {
                                Text(L10n.key("users.toggle.blockDashboard"))
                                    .font(.callout)
                                    .foregroundStyle(Color.white)
                            }
                            .toggleStyle(SwitchToggleStyle(tint: appTheme.accent))
                        }

                        roleSelector()

                        if let editErrorMessage {
                            Text(editErrorMessage)
                                .font(.footnote)
                                .foregroundStyle(Color.red)
                        }
                    }
                    .padding(24)
                }

                if isSavingUser {
                    ProgressView("Saving…")
                        .padding(20)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }
            }
            .navigationTitle(L10n.key("users.edit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelEditingUser()
                        onClose()
                    }
                        .foregroundStyle(appTheme.accent)
                        .disabled(isSavingUser)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await saveEditedUser() }
                    } label: {
                        if isSavingUser {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .foregroundStyle(appTheme.accent)
                    .disabled(isSavingUser || editUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .keyboardDismissToolbar()
            .onAppear {
                syncEditRoleState(with: user)
                roleSelectionVersion = UUID()
            }
        }
    }

    @ViewBuilder
    private func reset2FABanner(message: String, isError: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isError ? "exclamationmark.triangle" : "checkmark.seal")
                .foregroundStyle(isError ? Color.red : Color.green)
            Text(message)
                .font(.footnote)
                .foregroundStyle(isError ? Color.red : Color.green)
            Spacer(minLength: 0)
            Button {
                withAnimation {
                    reset2FAMessage = nil
                    showReset2FAOverlay = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
            }
            .tint(.white.opacity(0.7))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isError ? Color.red.opacity(0.18) : Color.green.opacity(0.2))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private func reset2FAOverlay(message: String, isError: Bool) -> some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: isError ? "exclamationmark.triangle" : "checkmark.seal.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(isError ? Color.red : Color.green)

                Text(isError ? L10n.key("Reset Failed") : L10n.key("Reset Complete"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.white)

                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .padding(.horizontal)

                Button {
                    withAnimation {
                        showReset2FAOverlay = false
                        reset2FAMessage = nil
                    }
                } label: {
                    Text(L10n.key("Got it"))
                        .frame(maxWidth: .infinity)
                }
                .primaryButton()
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.black.opacity(0.75))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 32)
        }
        .transition(.opacity.combined(with: .scale))
    }

    @ViewBuilder
    private func resetPasswordSheet(for user: RMMUser) -> some View {
        NavigationStack {
            ZStack {
                DarkGradientBackground()

                VStack(alignment: .leading, spacing: 20) {
                    SectionHeader(L10n.key("Reset Password"), subtitle: user.displayName, systemImage: "key")

                    VStack(alignment: .leading, spacing: 10) {
                        Text("NEW PASSWORD")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .kerning(1.1)
                        SecureField("Enter new password", text: $resetPassword)
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

                    if let resetErrorMessage {
                        Text(resetErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.red)
                    }

                    Spacer()
                }
                .padding(24)

                if isResettingPassword {
                    ProgressView("Resetting…")
                        .padding(20)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }
            }
            .navigationTitle(L10n.key("Reset Password"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelResettingPassword() }
                        .foregroundStyle(appTheme.accent)
                        .disabled(isResettingPassword)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await resetUserPassword() }
                    } label: {
                        if isResettingPassword {
                            ProgressView()
                        } else {
                            Text("Reset")
                        }
                    }
                    .foregroundStyle(appTheme.accent)
                    .disabled(isResettingPassword || resetPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .keyboardDismissToolbar()
        }
    }

    @ViewBuilder
    private func activeSessionsSheet(for user: RMMUser) -> some View {
        NavigationStack {
            ZStack {
                DarkGradientBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        SectionHeader(L10n.key("Active Sessions"), subtitle: user.displayName, systemImage: "person.badge.clock")

                        Button {
                            Task { await logoutAllSessions(for: user) }
                        } label: {
                            if isLoggingOutAllSessions {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Label("Logout of All Sessions", systemImage: "rectangle.portrait.and.arrow.right")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.red)
                        .disabled(isLoggingOutAllSessions || isLoadingSessions || userSessions.isEmpty)

                        if isLoadingSessions {
                            HStack {
                                ProgressView()
                                Text("Loading sessions…")
                                    .font(.footnote)
                                    .foregroundStyle(Color.white.opacity(0.7))
                            }
                        } else if let sessionsErrorMessage {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(sessionsErrorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(Color.red)
                                Button {
                                    Task { await loadSessions(for: user, force: true) }
                                } label: {
                                    Label("Retry", systemImage: "arrow.clockwise")
                                        .frame(maxWidth: .infinity)
                                }
                                .primaryButton()
                            }
                        } else if userSessions.isEmpty {
                            Text("No active sessions for this user.")
                                .font(.footnote)
                                .foregroundStyle(Color.white.opacity(0.7))
                        } else {
                            LazyVStack(spacing: 14) {
                                ForEach(userSessions) { session in
                                    sessionRow(session, for: user)
                                }
                            }
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle(L10n.key("Active Sessions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        sessionUser = nil
                        resetSessionState()
                    }
                    .foregroundStyle(appTheme.accent)
                    .disabled(isLoadingSessions || isLoggingOutAllSessions)
                }
            }
            .task {
                await loadSessions(for: user)
            }
            .onDisappear {
                resetSessionState()
            }
        }
    }

    private func sessionRow(_ session: UserSession, for user: RMMUser) -> some View {
        let isDeleting = deletingSessionDigests.contains(session.digest)
        let createdText = formatLastSeenTimestamp(session.created, customFormat: lastSeenDateFormat)
        let expiryText = formatLastSeenTimestamp(session.expiry, customFormat: lastSeenDateFormat)

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Digest")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.6))
                Text(session.digest)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Color.white)
                    .textSelection(.enabled)
            }

            infoRow(title: "Created", value: createdText)
            infoRow(title: "Expiry", value: expiryText)

            Button {
                Task { await logoutSession(session) }
            } label: {
                if isDeleting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Logout Session", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .tint(Color.red.opacity(0.85))
            .disabled(isDeleting || isLoggingOutAllSessions)
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

    private func editInput(title: String, text: Binding<String>, keyboard: UIKeyboardType = .default, capitalization: TextInputAutocapitalization = .never) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.6))
                .kerning(1.1)
            TextField(title, text: text)
                .platformKeyboardType(keyboard)
                .textInputAutocapitalization(capitalization)
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
    }

    @ViewBuilder
    private func roleSelector() -> some View {
        let sortedRoles = roles.values.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
        if !sortedRoles.isEmpty {
            let currentRoleID = editRoleID ?? editingUser?.role ?? sortedRoles.first!.id

            VStack(alignment: .leading, spacing: 10) {
                Text("ROLE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .kerning(1.1)

                Menu {
                    ForEach(sortedRoles) { role in
                        Button {
                            editRoleID = role.id
                            editRoleText = String(role.id)
                            editRoleName = role.displayName
                            roleSelectionVersion = UUID()
                        } label: {
                            if role.id == (editRoleID ?? editingUser?.role ?? sortedRoles.first!.id) {
                                Label(role.displayName, systemImage: "checkmark")
                            } else {
                                Text(role.displayName)
                            }
                        }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(editRoleName.isEmpty ? selectedRoleName(for: editRoleID ?? currentRoleID) : editRoleName)
                                .font(.callout)
                                .foregroundStyle(Color.white)
                            Text("Tap to change")
                                .font(.caption2)
                                .foregroundStyle(Color.white.opacity(0.55))
                        }
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
                // Force menu label refresh when selection changes
                .id(roleSelectionVersion)
                .onAppear {
                    refreshEditRoleName()
                }
                .onChange(of: editRoleID) { _, _ in
                    refreshEditRoleName()
                }
                .onChange(of: rolesVersion) { _, _ in
                    refreshEditRoleName()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("ROLE ID")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .kerning(1.1)
                TextField("Role ID", text: $editRoleText)
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
        }
    }

    private func userRow(for user: RMMUser) -> some View {
        let lastLoginText = formatLastSeenTimestamp(user.lastLogin, customFormat: lastSeenDateFormat)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.displayName)
                        .font(.headline)
                    Text(user.username)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.65))
                }
                Spacer(minLength: 0)
                statusBadge(isActive: user.isActive)

                  Menu {
                      Button("Edit", systemImage: "pencil") {
                          beginEditingUser(user)
                      }
                      Button("Active User Sessions", systemImage: "person.badge.clock") {
                          beginViewingSessions(user)
                      }
                      Button(L10n.key("Reset Password"), systemImage: "key") {
                          beginResettingPassword(user)
                      }
                      Button(L10n.key("Reset 2FA"), systemImage: "lock.rotation") {
                          Task { await resetUser2FA(user) }
                      }
                  } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(Color.white.opacity(0.8))
                }
            }

            if let email = user.email, !email.isEmpty {
                infoRow(title: L10n.key("users.field.email"), value: email)
            }

            infoRow(title: L10n.key("users.field.lastLogin"), value: lastLoginText)

            if let ip = user.lastLoginIP, !ip.isEmpty {
                infoRow(title: L10n.key("users.field.lastLoginIp"), value: ip)
            }

            HStack(spacing: 8) {
                badge(text: roleDisplayName(for: user), tint: Color.white.opacity(0.12))
                badge(text: user.canAccessDashboard ? L10n.key("users.dashboard.access") : L10n.key("users.dashboard.blocked"), tint: user.canAccessDashboard ? appTheme.accent.opacity(0.18) : Color.red.opacity(0.22))
            }
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

    private func infoRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.6))
            Text(value)
                .font(.callout)
                .foregroundStyle(Color.white)
        }
    }

    private func badge(text: String, tint: Color) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(tint)
            )
    }

    private func statusBadge(isActive: Bool) -> some View {
        badge(text: isActive ? L10n.key("users.status.active") : L10n.key("users.status.disabled"), tint: isActive ? appTheme.accent.opacity(0.2) : Color.red.opacity(0.25))
    }

    private func roleDisplayName(for user: RMMUser) -> String {
        guard let roleID = user.role, let role = roles[roleID] else {
            return user.roleLabel
        }
        return role.displayName
    }

    private func selectedRoleName(for roleID: Int) -> String {
        roles[roleID]?.displayName ?? "Role \(roleID)"
    }

    @MainActor
    private func saveEditedUser() async {
        guard let original = editingUser else { return }

        let trimmedUsername = editUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            editErrorMessage = "Username is required."
            return
        }

        let trimmedFirstName = editFirstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLastName = editLastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = editEmail.trimmingCharacters(in: .whitespacesAndNewlines)

        let finalRole: Int?
        if roles.isEmpty {
            finalRole = Int(editRoleText.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            if let editRoleID {
                finalRole = editRoleID
            } else if let existingRole = original.role {
                finalRole = existingRole
            } else {
                finalRole = roles.values.min(by: { $0.displayName.lowercased() < $1.displayName.lowercased() })?.id
            }
        }

        guard let roleValue = finalRole else {
            editErrorMessage = "Select a role."
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            editErrorMessage = "Missing API key for this instance."
            return
        }

        let base = settings.baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(base)/accounts/\(original.id)/users/") else {
            editErrorMessage = "Invalid base URL."
            return
        }

        let payload = UserUpdatePayload(
            is_active: editIsActive,
            block_dashboard_login: editBlockDashboard,
            id: original.id,
            username: trimmedUsername,
            first_name: trimmedFirstName.nonEmpty,
            last_name: trimmedLastName.nonEmpty,
            email: trimmedEmail.nonEmpty,
            last_login_ip: original.lastLoginIP,
            role: roleValue,
            date_format: original.dateFormat,
            social_accounts: original.socialAccounts ?? []
        )

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 45
        request.addDefaultHeaders(apiKey: apiKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(payload)
        } catch {
            editErrorMessage = "Failed to encode request."
            DiagnosticLogger.shared.appendError("Failed to encode user update payload: \(error.localizedDescription)")
            return
        }

        DiagnosticLogger.shared.logHTTPRequest(
            method: "PUT",
            url: url.absoluteString,
            headers: request.allHTTPHeaderFields ?? [:]
        )

        isSavingUser = true
        editErrorMessage = nil
        defer { isSavingUser = false }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                editErrorMessage = "Unexpected response."
                DiagnosticLogger.shared.appendError("User update response missing HTTPURLResponse.")
                return
            }

            DiagnosticLogger.shared.logHTTPResponse(
                method: "PUT",
                url: url.absoluteString,
                status: http.statusCode,
                data: data
            )

            switch http.statusCode {
            case 200, 201:
                if let updated = try? JSONDecoder().decode(RMMUser.self, from: data) {
                    upsertUser(updated)
                    DiagnosticLogger.shared.append("Updated user \(updated.username)")
                    cancelEditingUser()
                } else {
                    DiagnosticLogger.shared.appendWarning("User update successful but response decoding failed; refreshing list.")
                    await loadUsers(apiKey: apiKey, force: true)
                    cancelEditingUser()
                }
            case 204:
                DiagnosticLogger.shared.append("User update returned 204; refreshing list.")
                await loadUsers(apiKey: apiKey, force: true)
                cancelEditingUser()
            case 400:
                editErrorMessage = "Validation failed. Check the entered details."
            case 401:
                editErrorMessage = "Invalid API key or insufficient permissions."
            case 403:
                editErrorMessage = "You do not have permission to edit this user."
            default:
                editErrorMessage = "HTTP \(http.statusCode)."
            }
        } catch {
            editErrorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Failed to update user: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func upsertUser(_ user: RMMUser) {
        if let index = users.firstIndex(where: { $0.id == user.id }) {
            users[index] = user
        } else {
            users.append(user)
        }
        users.sort { $0.username.lowercased() < $1.username.lowercased() }
    }

    @MainActor
    private func resetUserPassword() async {
        guard let user = resettingUser else { return }

        let trimmedPassword = resetPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassword.isEmpty else {
            resetErrorMessage = "Password is required."
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            resetErrorMessage = "Missing API key for this instance."
            return
        }

        let base = settings.baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(base)/accounts/users/reset/") else {
            resetErrorMessage = "Invalid base URL."
            return
        }

        let payload = PasswordResetPayload(id: user.id, password: trimmedPassword)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.addDefaultHeaders(apiKey: apiKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(payload)
        } catch {
            resetErrorMessage = "Failed to encode request."
            DiagnosticLogger.shared.appendError("Failed to encode password reset payload: \(error.localizedDescription)")
            return
        }

        DiagnosticLogger.shared.logHTTPRequest(
            method: "POST",
            url: url.absoluteString,
            headers: request.allHTTPHeaderFields ?? [:]
        )

        isResettingPassword = true
        resetErrorMessage = nil
        defer { isResettingPassword = false }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                resetErrorMessage = "Unexpected response."
                DiagnosticLogger.shared.appendError("Password reset response missing HTTPURLResponse.")
                return
            }

            DiagnosticLogger.shared.logHTTPResponse(
                method: "POST",
                url: url.absoluteString,
                status: http.statusCode,
                data: data
            )

            switch http.statusCode {
            case 200:
                if let responseString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), responseString.lowercased() == "\"ok\"" || responseString.lowercased() == "ok" {
                    DiagnosticLogger.shared.append("Password reset for user \(user.username)")
                    cancelResettingPassword()
                } else {
                    resetErrorMessage = "Unexpected response body."
                }
            case 204:
                DiagnosticLogger.shared.append("Password reset returned 204 for user \(user.username)")
                cancelResettingPassword()
            case 400:
                resetErrorMessage = "Password rejected by server."
            case 401:
                resetErrorMessage = "Invalid API key or insufficient permissions."
            case 403:
                resetErrorMessage = "You do not have permission to reset passwords."
            default:
                resetErrorMessage = "HTTP \(http.statusCode)."
            }
        } catch {
            resetErrorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Failed to reset password: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func resetUser2FA(_ user: RMMUser) async {
        reset2FAMessage = nil
        reset2FAIsError = false
        showReset2FAOverlay = false

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            reset2FAIsError = true
            showReset2FAOverlay = true
            reset2FAMessage = "Missing API key for this instance."
            return
        }

        let base = settings.baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(base)/accounts/users/reset_totp/") else {
            reset2FAIsError = true
            showReset2FAOverlay = true
            reset2FAMessage = "Invalid base URL."
            return
        }

        let payload = TwoFactorResetPayload(id: user.id)

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 45
        request.addDefaultHeaders(apiKey: apiKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(payload)
        } catch {
            reset2FAIsError = true
            showReset2FAOverlay = true
            reset2FAMessage = "Failed to encode 2FA reset request."
            DiagnosticLogger.shared.appendError("Failed to encode TOTP reset payload: \(error.localizedDescription)")
            return
        }

        DiagnosticLogger.shared.logHTTPRequest(
            method: "PUT",
            url: url.absoluteString,
            headers: request.allHTTPHeaderFields ?? [:]
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                reset2FAIsError = true
                showReset2FAOverlay = true
                reset2FAMessage = "Unexpected response resetting 2FA."
                DiagnosticLogger.shared.appendError("TOTP reset response missing HTTPURLResponse.")
                return
            }

            DiagnosticLogger.shared.logHTTPResponse(
                method: "PUT",
                url: url.absoluteString,
                status: http.statusCode,
                data: data
            )

            switch http.statusCode {
            case 200, 204:
                if var responseString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !responseString.isEmpty {
                    if responseString.hasPrefix("\"") && responseString.hasSuffix("\"") {
                        responseString = String(responseString.dropFirst().dropLast())
                    }
                    DiagnosticLogger.shared.append("Reset 2FA for user \(user.username): \(responseString)")
                    showReset2FAOverlay = true
                    reset2FAMessage = responseString
                } else {
                    DiagnosticLogger.shared.append("Reset 2FA for user \(user.username)")
                    showReset2FAOverlay = true
                    reset2FAMessage = L10n.key("users.reset2fa.completed")
                }
            case 400:
                reset2FAIsError = true
                showReset2FAOverlay = true
                reset2FAMessage = "2FA reset rejected."
            case 401:
                reset2FAIsError = true
                showReset2FAOverlay = true
                reset2FAMessage = "Invalid API key or insufficient permissions."
            case 403:
                reset2FAIsError = true
                showReset2FAOverlay = true
                reset2FAMessage = "You do not have permission to reset 2FA."
            default:
                reset2FAIsError = true
                showReset2FAOverlay = true
                reset2FAMessage = "HTTP \(http.statusCode) while resetting 2FA."
            }
        } catch {
            reset2FAIsError = true
            showReset2FAOverlay = true
            reset2FAMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Failed to reset 2FA: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func loadUsers(apiKey: String, force: Bool = false) async {
        guard !isLoading || force else { return }

        if settings.baseURL.isDemoEntry {
            DiagnosticLogger.shared.append("UserAdministrationView loading demo users.")
            loadDemoUsers()
            return
        }

        let base = settings.baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(base)/accounts/users/") else {
            errorMessage = "Invalid base URL."
            users = []
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
                errorMessage = "Unexpected response."
                DiagnosticLogger.shared.appendError("User list response missing HTTPURLResponse.")
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
                    let decoded = try decoder.decode([RMMUser].self, from: data)
                    users = decoded.sorted { $0.username.lowercased() < $1.username.lowercased() }
                } catch {
                    errorMessage = "Failed to decode response."
                    users = []
                    DiagnosticLogger.shared.appendError("Failed to decode users: \(error.localizedDescription)")
                }
            case 403:
                errorMessage = "You do not have permission to access User Administration."
                users = []
            case 401:
                errorMessage = "Invalid API key or insufficient permissions."
                users = []
            default:
                errorMessage = "HTTP \(http.statusCode)."
                users = []
            }
        } catch {
            if error.isCancelledRequest {
                return
            }
            errorMessage = error.localizedDescription
            users = []
            DiagnosticLogger.shared.appendError("Failed to load users: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func loadRoles(apiKey: String, force: Bool = false) async {
        if !force && !roles.isEmpty { return }

        if settings.baseURL.isDemoEntry {
            loadDemoRoles()
            return
        }

        let base = settings.baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(base)/accounts/roles/") else {
            roleErrorMessage = "Invalid base URL."
            roles = [:]
            return
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
                roleErrorMessage = "Unexpected response while loading roles."
                DiagnosticLogger.shared.appendError("Roles response missing HTTPURLResponse.")
                roles = [:]
                rolesVersion += 1
                refreshEditRoleName()
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
                    let decoded = try decoder.decode([RMMRole].self, from: data)
                    roles = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
                    roleErrorMessage = nil
                    rolesVersion += 1
                    refreshEditRoleName()
                } catch {
                    roleErrorMessage = "Failed to decode roles."
                    roles = [:]
                    rolesVersion += 1
                    refreshEditRoleName()
                    DiagnosticLogger.shared.appendError("Failed to decode roles: \(error.localizedDescription)")
                }
            case 403:
                roleErrorMessage = "Role information restricted; showing role IDs."
                roles = [:]
                rolesVersion += 1
                refreshEditRoleName()
            case 401:
                roleErrorMessage = "Invalid API key or insufficient permissions to load roles."
                roles = [:]
                rolesVersion += 1
                refreshEditRoleName()
            default:
                roleErrorMessage = "HTTP \(http.statusCode) while loading roles."
                roles = [:]
                rolesVersion += 1
                refreshEditRoleName()
            }
        } catch {
            if error.isCancelledRequest {
                return
            }
            roleErrorMessage = error.localizedDescription
            roles = [:]
            rolesVersion += 1
            refreshEditRoleName()
            DiagnosticLogger.shared.appendError("Failed to load roles: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func loadInitialData(force: Bool = false) async {
        if settings.baseURL.isDemoEntry {
            loadDemoRoles()
            loadDemoUsers()
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            let message = L10n.key("connection.apiKeyMissingUpdate")
            errorMessage = message
            roleErrorMessage = message
            users = []
            roles = [:]
            return
        }

        await loadRoles(apiKey: apiKey, force: force)
        await loadUsers(apiKey: apiKey, force: force)
    }

    @MainActor
    private func loadDemoSessions() {
        isLoadingSessions = false
        sessionsErrorMessage = nil
        userSessions = [
            UserSession(
                digest: "demo-session-1",
                user: "demo.user",
                created: DateConstants.lastSeenISOFormatterWithFractional.string(from: Date().addingTimeInterval(-7200)),
                expiry: DateConstants.lastSeenISOFormatterWithFractional.string(from: Date().addingTimeInterval(7200))
            )
        ]
    }

    @MainActor
    private func loadDemoUsers() {
        isLoading = false
        errorMessage = nil
        users = [
            RMMUser(
                id: 1,
                username: "demo.user",
                firstName: "Demo",
                lastName: "User",
                email: "demo@example.com",
                isActive: true,
                lastLogin: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)),
                lastLoginIP: "203.0.113.1",
                role: 3,
                blockDashboardLogin: false,
                dateFormat: "DD/MM/YYYY",
                socialAccounts: []
            )
        ]
    }

    @MainActor
    private func loadSessions(for user: RMMUser, force: Bool = false) async {
        guard !isLoadingSessions || force else { return }

        if settings.baseURL.isDemoEntry {
            loadDemoSessions()
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            sessionsErrorMessage = "Missing API key for this instance."
            userSessions = []
            return
        }

        let base = settings.baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(base)/accounts/users/\(user.id)/sessions/") else {
            sessionsErrorMessage = "Invalid base URL."
            userSessions = []
            return
        }

        isLoadingSessions = true
        sessionsErrorMessage = nil

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
                sessionsErrorMessage = "Unexpected response while loading sessions."
                DiagnosticLogger.shared.appendError("Sessions response missing HTTPURLResponse.")
                userSessions = []
                isLoadingSessions = false
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
                    let decoded = try decoder.decode([UserSession].self, from: data)
                    userSessions = decoded.sorted { lhs, rhs in
                        (lhs.expiryDate ?? .distantPast) > (rhs.expiryDate ?? .distantPast)
                    }
                    sessionsErrorMessage = nil
                } catch {
                    sessionsErrorMessage = "Failed to decode sessions."
                    userSessions = []
                    DiagnosticLogger.shared.appendError("Failed to decode sessions: \(error.localizedDescription)")
                }
            case 403:
                sessionsErrorMessage = "You do not have permission to view sessions."
                userSessions = []
            case 401:
                sessionsErrorMessage = "Invalid API key or insufficient permissions."
                userSessions = []
            default:
                sessionsErrorMessage = "HTTP \(http.statusCode) while loading sessions."
                userSessions = []
            }
        } catch {
            if error.isCancelledRequest {
                return
            }
            sessionsErrorMessage = error.localizedDescription
            userSessions = []
            DiagnosticLogger.shared.appendError("Failed to load sessions: \(error.localizedDescription)")
        }

        isLoadingSessions = false
    }

    @MainActor
    private func logoutSession(_ session: UserSession) async {
        guard !deletingSessionDigests.contains(session.digest), !isLoggingOutAllSessions else { return }

        deletingSessionDigests.insert(session.digest)
        defer { deletingSessionDigests.remove(session.digest) }

        if settings.baseURL.isDemoEntry {
            withAnimation {
                userSessions.removeAll { $0.digest == session.digest }
            }
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            sessionsErrorMessage = "Missing API key for this instance."
            return
        }

        let base = settings.baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(base)/accounts/sessions/\(session.digest)/") else {
            sessionsErrorMessage = "Invalid base URL."
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
                sessionsErrorMessage = "Unexpected response while logging out session."
                DiagnosticLogger.shared.appendError("Session delete response missing HTTPURLResponse.")
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
                withAnimation {
                    userSessions.removeAll { $0.digest == session.digest }
                }
                sessionsErrorMessage = nil
            case 404:
                withAnimation {
                    userSessions.removeAll { $0.digest == session.digest }
                }
                sessionsErrorMessage = "Session already expired."
            case 401:
                sessionsErrorMessage = "Invalid API key or insufficient permissions."
            case 403:
                sessionsErrorMessage = "You do not have permission to manage sessions."
            default:
                let serverMessage = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let serverMessage, !serverMessage.isEmpty {
                    sessionsErrorMessage = serverMessage
                } else {
                    sessionsErrorMessage = "HTTP \(http.statusCode) while logging out session."
                }
            }
        } catch {
            sessionsErrorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Failed to delete session: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func logoutAllSessions(for user: RMMUser) async {
        guard !isLoggingOutAllSessions else { return }

        isLoggingOutAllSessions = true
        defer { isLoggingOutAllSessions = false }

        if settings.baseURL.isDemoEntry {
            withAnimation { userSessions = [] }
            return
        }

        guard let apiKey = KeychainHelper.shared.getAPIKey(identifier: settings.keychainKey), !apiKey.isEmpty else {
            sessionsErrorMessage = "Missing API key for this instance."
            return
        }

        let base = settings.baseURL.removingTrailingSlash()
        guard let url = URL(string: "\(base)/accounts/users/\(user.id)/sessions/") else {
            sessionsErrorMessage = "Invalid base URL."
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
                sessionsErrorMessage = "Unexpected response while logging out all sessions."
                DiagnosticLogger.shared.appendError("Session bulk delete response missing HTTPURLResponse.")
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
                withAnimation { userSessions = [] }
                sessionsErrorMessage = nil
            case 401:
                sessionsErrorMessage = "Invalid API key or insufficient permissions."
            case 403:
                sessionsErrorMessage = "You do not have permission to manage sessions."
            default:
                let serverMessage = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let serverMessage, !serverMessage.isEmpty {
                    sessionsErrorMessage = serverMessage
                } else {
                    sessionsErrorMessage = "HTTP \(http.statusCode) while logging out sessions."
                }
            }
        } catch {
            sessionsErrorMessage = error.localizedDescription
            DiagnosticLogger.shared.appendError("Failed to delete all sessions: \(error.localizedDescription)")
        }
    }

    private struct UserSession: Identifiable, Decodable, Hashable {
        let digest: String
        let user: String
        let created: String
        let expiry: String

        var id: String { digest }

        var createdDisplay: String { formatLastSeenTimestamp(created) }
        var expiryDisplay: String { formatLastSeenTimestamp(expiry) }

        var expiryDate: Date? {
            DateConstants.lastSeenISOFormatterWithFractional.date(from: expiry) ?? DateConstants.lastSeenISOFormatter.date(from: expiry)
        }
    }

    @MainActor
    private func loadDemoRoles() {
        roleErrorMessage = nil
        roles = [
            3: RMMRole(id: 3, name: "Super User")
        ]
    }
}

private struct UserUpdatePayload: Encodable {
    let is_active: Bool
    let block_dashboard_login: Bool
    let id: Int
    let username: String
    let first_name: String?
    let last_name: String?
    let email: String?
    let last_login_ip: String?
    let role: Int?
    let date_format: String?
    let social_accounts: [Int]
}

private struct PasswordResetPayload: Encodable {
    let id: Int
    let password: String
}

private struct TwoFactorResetPayload: Encodable {
    let id: Int
}
