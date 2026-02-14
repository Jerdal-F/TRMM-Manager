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
        let sanitizedMessage = redactSensitiveData(message)
        do {
            let fileHandle = try openLogFileHandle(at: url)
            if sanitizedMessage.contains("\n") {
                try writeMultiline(sanitizedMessage, timestamp: timestamp, to: fileHandle)
            } else {
                try writeLogEntry("\(timestamp): \(sanitizedMessage)\n", to: fileHandle)
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
        let safeURL = redactAgentIdInUrl(url)
        append("HTTP Request: \(method) \(safeURL) Headers: \(sanitized)")
    }

    func logHTTPResponse(method: String, url: String, status: Int, data: Data?) {
        let responseBody: String
        let safeURL = redactAgentIdInUrl(url)
        if containsSensitiveData(url: url) {
            responseBody = "[REDACTED]"
        } else if let data = data, let responseString = String(data: data, encoding: .utf8) {
            if url.contains("/agents/") {
                if !responseString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) == nil {
                    let redacted = redactSensitiveData(responseString)
                    let snippet = redacted.count > 300
                        ? String(redacted.prefix(300)) + "..."
                        : redacted
                    appendError("Invalid JSON response for \(method) \(safeURL). Body: \(snippet)")
                }
                responseBody = redactSensitiveData(responseString)
            } else {
                let trimmed = responseString.count > 200
                    ? String(responseString.prefix(200)) + "..."
                    : responseString
                responseBody = redactSensitiveData(trimmed)
            }
        } else {
            responseBody = "No response body."
        }
        append("HTTP Response: \(status) for \(method) \(safeURL). Response Body: \(responseBody)")
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

    private func redactSensitiveData(_ input: String) -> String {
        var text = input
        text = redactAgentIdInUrl(text)
        text = redactJsonFields(in: text)
        text = redactLabeledFields(in: text)
        text = redactIPAddresses(in: text)
        return text
    }

    private func redactJsonFields(in text: String) -> String {
        var redacted = text
        let quotedKeys = "(agent_id|serial_number|username|user|public_ip|local_ips|custom_fields|notes|checks|tasks|processes)"
        let patterns = [
            "\"\(quotedKeys)\"\\s*:\\s*\"[^\"]*\"",
            "\"\(quotedKeys)\"\\s*:\\s*\[[^\]]*\]",
            "\"\(quotedKeys)\"\\s*:\\s*\{[^}]*\}",
            "\"\(quotedKeys)\"\\s*:\\s*[^,}\"]+"
        ]
        for pattern in patterns {
            redacted = redactRegex(pattern, in: redacted) { match in
                guard match.numberOfRanges >= 2,
                      let keyRange = Range(match.range(at: 1), in: redacted) else {
                    return "[REDACTED]"
                }
                let key = redacted[keyRange]
                return "\"\(key)\":\"[REDACTED]\""
            }
        }
        return redacted
    }

    private func redactLabeledFields(in text: String) -> String {
        var redacted = text
        let patterns = [
            "(?i)(agent\\s*id\\s*[:=]\\s*)([^,\n]+)",
            "(?i)(serial\\s*number\\s*[:=]\\s*)([^,\n]+)",
            "(?i)(user\\s*[:=]\\s*)([^,\n]+)",
            "(?i)(lan\\s*[:=]\\s*)([^,\n]+)",
            "(?i)(ip\\s*[:=]\\s*)([^,\n]+)",
            "(?i)(custom\\s*fields?\\s*[:=]\\s*)([^,\n]+)",
            "(?i)(notes?\\s*[:=]\\s*)([^,\n]+)",
            "(?i)(checks?\\s*[:=]\\s*)([^,\n]+)",
            "(?i)(tasks?\\s*[:=]\\s*)([^,\n]+)",
            "(?i)(process(?:es)?\\s*[:=]\\s*)([^,\n]+)"
        ]
        for pattern in patterns {
            redacted = redactRegex(pattern, in: redacted) { match in
                guard match.numberOfRanges >= 2,
                      let labelRange = Range(match.range(at: 1), in: redacted) else {
                    return "[REDACTED]"
                }
                let label = redacted[labelRange]
                return "\(label)[REDACTED]"
            }
        }
        return redacted
    }

    private func redactIPAddresses(in text: String) -> String {
        let ipv4Pattern = "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b"
        return redactRegex(ipv4Pattern, in: text) { _ in "[REDACTED_IP]" }
    }

    private func redactAgentIdInUrl(_ text: String) -> String {
        let pattern = "(/agents/)([^/]+)(/?)"
        return redactRegex(pattern, in: text) { match in
            guard match.numberOfRanges >= 4,
                  let prefixRange = Range(match.range(at: 1), in: text),
                  let suffixRange = Range(match.range(at: 3), in: text) else {
                return "/agents/[REDACTED]"
            }
            let prefix = text[prefixRange]
            let suffix = text[suffixRange]
            return "\(prefix)[REDACTED]\(suffix)"
        }
    }

    private func redactRegex(_ pattern: String, in text: String, replacement: (NSTextCheckingResult) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var output = text
        var offset = 0
        regex.matches(in: text, options: [], range: range).forEach { match in
            guard let matchRange = Range(match.range, in: text) else { return }
            let replacementText = replacement(match)
            let start = text.distance(from: text.startIndex, to: matchRange.lowerBound) + offset
            let length = text.distance(from: matchRange.lowerBound, to: matchRange.upperBound)
            if let range = Range(NSRange(location: start, length: length), in: output) {
                output.replaceSubrange(range, with: replacementText)
                offset += replacementText.count - length
            }
        }
        return output
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
