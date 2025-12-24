//
//  TacticalRMMApp.swift
//  TacticalRMM
//
//  Created by Fredrik Jerdal on 28/02/2025.
//

import SwiftUI
import SwiftData

@main
struct TacticalRMMApp: App {
    // Configure the persistent container with RMMSettings in the schema.
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([RMMSettings.self])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    @AppStorage("selectedTheme") private var selectedThemeID: String = AppTheme.default.rawValue

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .environment(\.appTheme, AppTheme(rawValue: selectedThemeID) ?? .default)
        }
        .modelContainer(sharedModelContainer)
    }
}


