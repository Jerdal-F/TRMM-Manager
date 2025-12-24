import SwiftUI

struct ReleaseNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    @State private var notes: [ReleaseNote] = []
    @State private var loadError: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ZStack {
                DarkGradientBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        if isLoading {
                            ProgressView()
                                .padding(.top, 40)
                        } else if let loadError {
                            VStack(spacing: 12) {
                                Text(loadError)
                                    .font(.footnote)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(Color.red)
                                Button {
                                    loadNotes()
                                } label: {
                                    Label("Retry", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                                .tint(.cyan)
                            }
                            .padding(.top, 40)
                        } else if notes.isEmpty {
                            Text("No release notes found.")
                                .font(.footnote)
                                .foregroundStyle(Color.white.opacity(0.7))
                                .padding(.top, 40)
                        } else {
                            ForEach(notes) { note in
                                releaseNoteCard(for: note)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 28)
                }
            }
            .navigationTitle("What's New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(appTheme.accent)
                }
            }
            .onAppear { loadNotes() }
        }
    }

    private func releaseNoteCard(for note: ReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(note.version)
                    .font(.headline)
                    .foregroundStyle(Color.white)

                if note.isCurrentRelease {
                    Text("Current Release")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(appTheme.accent.opacity(0.2))
                        )
                        .foregroundStyle(appTheme.accent)
                }
            }

            Text(note.description)
                .font(.callout)
                .foregroundStyle(Color.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    private func loadNotes() {
        isLoading = true
        loadError = nil

        guard let url = Bundle.main.url(forResource: "ReleaseNotes", withExtension: "json") else {
            loadError = "Missing ReleaseNotes.json in app bundle."
            isLoading = false
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            var decoded = try decoder.decode([ReleaseNote].self, from: data)

            if let matchingIndex = decoded.firstIndex(where: { $0.version == Bundle.main.currentVersion }) {
                decoded[matchingIndex].isCurrentRelease = true
            } else if !decoded.isEmpty {
                decoded[0].isCurrentRelease = true
            }

            notes = decoded
            isLoading = false
        } catch {
            loadError = "Failed to load release notes: \(error.localizedDescription)"
            DiagnosticLogger.shared.appendError("Release notes load failed: \(error.localizedDescription)")
            isLoading = false
        }
    }
}

private struct ReleaseNote: Decodable, Identifiable {
    let version: String
    let description: String
    var isCurrentRelease: Bool

    var id: String { version }

    private enum CodingKeys: String, CodingKey {
        case version
        case description
        case isCurrentRelease
        case legacyIsCurrent = "isCurrent"
    }

    init(version: String, description: String, isCurrentRelease: Bool = false) {
        self.version = version
        self.description = description
        self.isCurrentRelease = isCurrentRelease
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        description = try container.decode(String.self, forKey: .description)

        if let explicitFlag = try container.decodeIfPresent(Bool.self, forKey: .isCurrentRelease) {
            isCurrentRelease = explicitFlag
        } else if let legacyFlag = try container.decodeIfPresent(Bool.self, forKey: .legacyIsCurrent) {
            isCurrentRelease = legacyFlag
        } else {
            isCurrentRelease = false
        }
    }
}

private extension Bundle {
    var currentVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
}
