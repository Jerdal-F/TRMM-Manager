import Foundation
import SwiftData

@Model
final class RMMSettings {
    var uuid: UUID = UUID()
    var displayName: String = "Default"
    var baseURL: String
    var keychainKey: String = ""

    init(displayName: String, baseURL: String) {
        let generated = UUID()
        self.uuid = generated
        self.displayName = displayName
        self.baseURL = baseURL
        self.keychainKey = "apiKey_\(generated.uuidString)"
    }

    init(baseURL: String) {
        let generated = UUID()
        self.uuid = generated
        self.displayName = "Default"
        self.baseURL = baseURL
        self.keychainKey = "apiKey_\(generated.uuidString)"
    }
}
