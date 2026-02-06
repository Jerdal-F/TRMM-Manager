import Foundation
import UIKit

final class DiagnosticLogger {
    static let shared = DiagnosticLogger()

    private let maxLinesPerBatch = 500
    private let maxLinesPerMessage = 1000

    private let fileName: String
    private let fileManager = FileManager.default
    private let sensitiveURLFragments: [String] = [
        "/core/keystore",
        "/core/codesign",
        "/core/settings",
        "/accounts/users/reset",
        "/accounts/users/reset_totp",
        "/accounts/users/",
        "/accounts/sessions",
        "/scripts/"
    ]
    private var logFileURL: URL? {
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return docs.appendingPathComponent(fileName)
    }

    private init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MM-yyyy HH-mm-ss"
        let dateString = formatter.string(from: Date())
        self.fileName = "\(dateString)-TRMM Manager.log"
        logDeviceInfo()
    }

    func append(_ message: String) {
        guard let url = logFileURL else { return }
        let timestamp = Date()
        do {
            let fileHandle = try openLogFileHandle(at: url)
            if message.contains("\n") {
                try writeMultiline(message, timestamp: timestamp, to: fileHandle)
            } else {
                try writeLogEntry("\(timestamp): \(message)\n", to: fileHandle)
            }
            fileHandle.closeFile()
            applyFileProtection(to: url)
        } catch {
            print("Error writing log: \(error)")
        }
    }

    func maskAPIKey(_ key: String) -> String {
        let length = key.count
        if length <= 8 {
            return String(repeating: "X", count: length)
        }
        let first = key.prefix(4)
        let last = key.suffix(4)
        return "\(first)XXXXXXXXXXXXXX\(last)"
    }

    func logHTTPRequest(method: String, url: String, headers: [String: String]) {
        let sanitized = sanitizeHeaders(headers)
        append("HTTP Request: \(method) \(url) Headers: \(sanitized)")
    }

    func logHTTPResponse(method: String, url: String, status: Int, data: Data?) {
        let responseBody: String
        if containsSensitiveData(url: url) {
            responseBody = "[REDACTED]"
        } else if let data = data, let responseString = String(data: data, encoding: .utf8) {
            if url.contains("/agents/") {
                responseBody = responseString
            } else {
                responseBody = responseString.count > 200
                    ? String(responseString.prefix(200)) + "..."
                    : responseString
            }
        } else {
            responseBody = "No response body."
        }
        append("HTTP Response: \(status) for \(method) \(url). Response Body: \(responseBody)")
    }

    func appendWarning(_ message: String) {
        append("WARNING: \(message)")
    }

    func appendError(_ message: String) {
        append("ERROR: \(message)")
    }

    func getLogFileURL() -> URL? {
        logFileURL
    }

    private func logDeviceInfo() {
        let device = UIDevice.current
        let processInfo = ProcessInfo.processInfo
        append("Device Version: \(device.name)")
        append("OS Version: \(device.systemName) \(device.systemVersion)")
        append("Model: \(device.model)")
        append("Identifier: \(device.identifierForVendor?.uuidString ?? "N/A")")
        append("Screen: \(UIScreen.main.bounds.width)x\(UIScreen.main.bounds.height) @\(UIScreen.main.scale)x")
        append("CPU Cores: \(processInfo.processorCount)")
        append("Physical Memory: \(processInfo.physicalMemory / 1_048_576) MB")
        if let info = Bundle.main.infoDictionary {
            let version = info["CFBundleShortVersionString"] as? String ?? "N/A"
            let build = info["CFBundleVersion"] as? String ?? "N/A"
            append("App Version: \(version) (build \(build))")
        }
    }

    private func sanitizeHeaders(_ headers: [String: String]) -> [String: String] {
        var sanitized = headers
        if sanitized["X-API-KEY"] != nil {
            sanitized["X-API-KEY"] = "[REDACTED]"
        }
        if let authorization = sanitized["Authorization"], authorization.lowercased().contains("token") {
            sanitized["Authorization"] = "Token [REDACTED]"
        }
        if sanitized["Authorization"] != nil {
            sanitized["Authorization"] = "[REDACTED]"
        }
        if sanitized["Cookie"] != nil {
            sanitized["Cookie"] = "[REDACTED]"
        }
        if sanitized["Set-Cookie"] != nil {
            sanitized["Set-Cookie"] = "[REDACTED]"
        }
        return sanitized
    }

    private func containsSensitiveData(url: String) -> Bool {
        sensitiveURLFragments.contains { fragment in url.contains(fragment) }
    }

    private func applyFileProtection(to url: URL) {
        do {
            try fileManager.setAttributes([
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ], ofItemAtPath: url.path)
        } catch {
            print("Failed to apply file protection: \(error)")
        }
    }

    private func openLogFileHandle(at url: URL) throws -> FileHandle {
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let fileHandle = try FileHandle(forWritingTo: url)
        fileHandle.seekToEndOfFile()
        return fileHandle
    }

    private func writeLogEntry(_ entry: String, to fileHandle: FileHandle) throws {
        if let data = entry.data(using: .utf8) {
            fileHandle.write(data)
        }
    }

    private func writeMultiline(_ message: String, timestamp: Date, to fileHandle: FileHandle) throws {
        var batch = ""
        var lineCount = 0
        var totalLines = 0
        var truncatedLines = 0
        message.enumerateLines { line, _ in
            if totalLines >= self.maxLinesPerMessage {
                truncatedLines += 1
                return
            }
            batch.append("\(timestamp): \(line)\n")
            lineCount += 1
            totalLines += 1
            if lineCount >= self.maxLinesPerBatch {
                try? self.writeLogEntry(batch, to: fileHandle)
                batch.removeAll(keepingCapacity: true)
                lineCount = 0
            }
        }

        if message.hasSuffix("\n") && totalLines < maxLinesPerMessage {
            batch.append("\(timestamp): \n")
            lineCount += 1
            totalLines += 1
        } else if message.hasSuffix("\n") {
            truncatedLines += 1
        }

        if truncatedLines > 0 {
            batch.append("\(timestamp): [TRUNCATED] Dropped \(truncatedLines) lines (cap \(maxLinesPerMessage)).\n")
            lineCount += 1
        }

        if lineCount > 0 {
            try writeLogEntry(batch, to: fileHandle)
        }
    }
}
