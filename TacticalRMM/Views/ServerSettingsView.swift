import SwiftUI

struct ServerSettingsView: View {
    let settings: RMMSettings
    @State private var showUserAdministration = false
    @State private var showDeployments = false
    @State private var showGeneralSettings = false
    @State private var showEmailSettings = false
    @State private var showSMSSettings = false
    @State private var showKeyStore = false
    @State private var showCodeSigning = false
    @State private var showScriptManager = false

    var body: some View {
        ZStack {
            DarkGradientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 18) {
                            SectionHeader(L10n.key("serverSettings.administration.title"), subtitle: L10n.key("serverSettings.administration.subtitle"), systemImage: "person.3.sequence.fill")

                            Button {
                                showUserAdministration = true
                            } label: {
                                Label(L10n.key("User Administration"), systemImage: "person.3.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .primaryButton()
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 18) {
                            SectionHeader(L10n.key("serverSettings.agents.title"), subtitle: L10n.key("serverSettings.agents.subtitle"), systemImage: "desktopcomputer")

                            Button {
                                showDeployments = true
                            } label: {
                                Label(L10n.key("Deployments"), systemImage: "shippingbox.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .primaryButton()

                            NavigationLink {
                                InstallAgentView(
                                    baseURL: installBaseURL,
                                    apiKey: installAPIKey
                                )
                            } label: {
                                Label(L10n.key("Install Agent"), systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .primaryButton()
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 18) {
                            SectionHeader(L10n.key("serverSettings.global.title"), subtitle: L10n.key("serverSettings.global.subtitle"), systemImage: "globe")

                            Button {
                                showGeneralSettings = true
                            } label: {
                                Label(L10n.key("General"), systemImage: "gearshape")
                                    .frame(maxWidth: .infinity)
                            }
                            .primaryButton()

                            Button {
                                showEmailSettings = true
                            } label: {
                                Label(L10n.key("Email Alerts"), systemImage: "envelope")
                                    .frame(maxWidth: .infinity)
                            }
                            .primaryButton()

                            Button {
                                showSMSSettings = true
                            } label: {
                                Label(L10n.key("SMS Alerts"), systemImage: "message")
                                    .frame(maxWidth: .infinity)
                            }
                            .primaryButton()

                            Button {
                                showKeyStore = true
                            } label: {
                                Label(L10n.key("Key Store"), systemImage: "key.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .primaryButton()

                            Button {
                                showCodeSigning = true
                            } label: {
                                Label(L10n.key("Code Signing"), systemImage: "checkmark.seal")
                                    .frame(maxWidth: .infinity)
                            }
                            .primaryButton()

                            Button {
                                showScriptManager = true
                            } label: {
                                Label(L10n.key("Script Manager"), systemImage: "terminal")
                                    .frame(maxWidth: .infinity)
                            }
                            .primaryButton()
                        }
                    }

                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }
        }
        .navigationTitle(settings.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showUserAdministration) {
            UserAdministrationView(settings: settings)
        }
        .navigationDestination(isPresented: $showDeployments) {
            DeploymentsView(settings: settings)
        }
        .navigationDestination(isPresented: $showGeneralSettings) {
            GeneralSettingsView(settings: settings)
        }
        .navigationDestination(isPresented: $showEmailSettings) {
            GeneralSettingsView(settings: settings, mode: .email)
        }
        .navigationDestination(isPresented: $showSMSSettings) {
            GeneralSettingsView(settings: settings, mode: .sms)
        }
        .navigationDestination(isPresented: $showKeyStore) {
            KeyStoreView(settings: settings)
        }
        .navigationDestination(isPresented: $showCodeSigning) {
            CodeSigningView(settings: settings)
        }
        .navigationDestination(isPresented: $showScriptManager) {
            ScriptManagerView(settings: settings)
        }
    }
}

private extension ServerSettingsView {
    var resolvedSettings: RMMSettings {
        if settings.keychainKey.isEmpty {
            settings.keychainKey = "apiKey_\(settings.uuid.uuidString)"
        }
        if settings.displayName.isEmpty {
            settings.displayName = settings.baseURL
        }
        return settings
    }

    var installBaseURL: String {
        let resolved = resolvedSettings
        let base = resolved.baseURL
        if base.isDemoEntry { return base }
        let lower = base.lowercased()
        if lower.hasPrefix("https://") {
            return base
        }
        if lower.hasPrefix("http://") {
            let suffix = String(base.dropFirst("http://".count))
            return "https://" + suffix
        }
        return "https://" + base
    }

    var installAPIKey: String {
        let resolved = resolvedSettings
        return KeychainHelper.shared.getAPIKey(identifier: resolved.keychainKey) ?? ""
    }
}
