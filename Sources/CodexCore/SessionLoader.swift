import Foundation
import Darwin

public enum SessionLoader {
    public static let sessionsRoot = URL(fileURLWithPath: "/Users/oliver/.codex/sessions")

    public static func sessionFiles(under relativePath: String) throws -> [URL] {
        let targetURL = sessionsRoot.appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            throw SessionError.invalidRoot(targetURL.path)
        }
        guard let enumerator = FileManager.default.enumerator(at: targetURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            return url
        }
    }

    public static func allSessionFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: sessionsRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            return url
        }
    }

    public static func sessionFilesSnapshot(under relativePath: String?) throws -> [URL: Date] {
        let targetURL: URL
        if let relativePath, !relativePath.isEmpty {
            targetURL = sessionsRoot.appending(path: relativePath)
        } else {
            targetURL = sessionsRoot
        }

        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            throw SessionError.invalidWatchTarget(targetURL.path)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: targetURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var snapshot: [URL: Date] = [:]
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values.contentModificationDate {
                snapshot[url] = modified
            }
        }
        return snapshot
    }

    public static func sessionFileSnapshot(for url: URL) throws -> Date? {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        return values.contentModificationDate
    }

    public static func fileIdentity(for url: URL) -> FileIdentity? {
        var info = stat()
        if stat(url.path, &info) == 0 {
            return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        }
        return nil
    }

    public static func loadSummary(from url: URL) throws -> SessionSummary? {
        let lines = try readLines(from: url)
        guard !lines.isEmpty else { return nil }

        var sessionId: String?
        var cwd = ""
        var originator = ""
        var startDate: Date?
        var endDate: Date?
        var firstUserMessage: String?
        var messageCount = 0

        for line in lines {
            let record = try decodeRecord(from: line)
            if let parsedDate = TimestampParser.parse(record.timestamp) {
                if startDate == nil { startDate = parsedDate }
                endDate = parsedDate
            }

            if record.type == "session_meta" {
                sessionId = record.payload["id"]?.stringValue
                cwd = record.payload["cwd"]?.stringValue ?? cwd
                originator = record.payload["originator"]?.stringValue ?? originator
            }

            if record.type == "response_item",
               record.payload["type"]?.stringValue == "message" {
                messageCount += 1
            }

            if firstUserMessage == nil, record.type == "response_item" {
                if record.payload["role"]?.stringValue == "user",
                   let content = record.payload["content"],
                   let message = extractText(from: content) {
                    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let titleSource = extractUserTitle(from: trimmed) {
                        firstUserMessage = titleSource
                    }
                }
            }
        }

        guard let id = sessionId, let start = startDate, let end = endDate else { return nil }
        let titleText = firstUserMessage ?? "(no user message)"
        let cleaned = SessionUtils.stripFilePaths(from: titleText)
        let flattened = SessionUtils.normalizeWhitespace(cleaned)
        let title = SessionUtils.truncated(flattened, limit: 200)
        return SessionSummary(
            id: id,
            startDate: start,
            endDate: end,
            cwd: cwd,
            title: title,
            originator: originator,
            messageCount: messageCount
        )
    }

    public static func loadMessages(from url: URL) throws -> [SessionMessage] {
        let lines = try readLines(from: url)
        var messages: [SessionMessage] = []

        for line in lines {
            let record = try decodeRecord(from: line)
            guard record.type == "response_item" else { continue }
            guard let role = record.payload["role"]?.stringValue else { continue }
            guard let content = record.payload["content"], let text = extractText(from: content) else { continue }
            guard let timestamp = TimestampParser.parse(record.timestamp) else { continue }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(SessionMessage(role: role, timestamp: timestamp, text: cleaned))
        }

        return messages
    }

    public static func findSessionFile(id: String) throws -> URL {
        if let byName = findSessionFileByName(id: id) {
            return byName
        }
        throw SessionError.sessionNotFound(id)
    }

    private static func findSessionFileByName(id: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            if url.lastPathComponent.contains(id) {
                return url
            }
        }
        return nil
    }

    private static func readLines(from url: URL) throws -> [Substring] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.split(whereSeparator: \.isNewline)
    }

    private static func decodeRecord(from line: Substring) throws -> SessionRecord {
        let data = Data(line.utf8)
        do {
            return try JSONDecoder().decode(SessionRecord.self, from: data)
        } catch {
            throw SessionError.malformedRecord(String(line.prefix(120)))
        }
    }

    private static func extractText(from value: JSONValue) -> String? {
        switch value {
        case .string(let text):
            return text
        case .array(let items):
            let parts = items.compactMap { item -> String? in
                if case .string(let text) = item { return text }
                if case .object(let object) = item {
                    if let text = object["text"]?.stringValue { return text }
                    if let text = object["content"]?.stringValue { return text }
                }
                return nil
            }
            return parts.isEmpty ? nil : parts.joined()
        case .object(let object):
            if let text = object["text"]?.stringValue { return text }
            if let text = object["content"]?.stringValue { return text }
            return nil
        case .number, .bool, .null:
            return nil
        }
    }
    
    // Private helpers for title extraction
    private static func isSkippableUserMessage(_ text: String) -> Bool {
        let prefixes = [
            "# AGENTS.md instructions",
            "<environment_context>"
        ]
        return prefixes.contains { text.hasPrefix($0) }
    }

    private static func extractUserTitle(from text: String) -> String? {
        if isSkippableUserMessage(text) {
            return nil
        }
        if let request = extractRequestSection(from: text) {
            return request
        }
        return text.isEmpty ? nil : text
    }

    private static func extractRequestSection(from text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## My request for Codex:" }) else {
            return nil
        }
        let contentStart = headerIndex + 1
        guard contentStart < lines.count else { return nil }
        var collected: [String] = []
        for line in lines[contentStart...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                break
            }
            collected.append(line)
        }
        let result = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
