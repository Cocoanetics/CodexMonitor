import ArgumentParser
import Foundation

private enum SessionError: Error, CustomStringConvertible {
    case invalidRoot(String)
    case sessionNotFound(String)
    case malformedRecord(String)

    var description: String {
        switch self {
        case .invalidRoot(let path):
            return "Invalid sessions path: \(path)"
        case .sessionNotFound(let id):
            return "Session not found: \(id)"
        case .malformedRecord(let detail):
            return "Malformed record: \(detail)"
        }
    }
}

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case object([String: JSONValue])
    case array([JSONValue])
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

private struct SessionRecord: Decodable {
    let timestamp: String
    let type: String
    let payload: [String: JSONValue]
}

private struct SessionSummary {
    let id: String
    let startDate: Date
    let endDate: Date
    let cwd: String
    let title: String
}

private struct SessionMessage {
    let role: String
    let timestamp: Date
    let text: String
}

private enum TimestampParser {
    static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: string)
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

private enum SessionLoader {
    static let sessionsRoot = URL(fileURLWithPath: "/Users/oliver/.codex/sessions")

    static func sessionFiles(under relativePath: String) throws -> [URL] {
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

    static func allSessionFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: sessionsRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            return url
        }
    }

    static func loadSummary(from url: URL) throws -> SessionSummary? {
        let lines = try readLines(from: url)
        guard !lines.isEmpty else { return nil }

        var sessionId: String?
        var cwd = ""
        var startDate: Date?
        var endDate: Date?
        var firstUserMessage: String?

        for line in lines {
            let record = try decodeRecord(from: line)
            if let parsedDate = TimestampParser.parse(record.timestamp) {
                if startDate == nil { startDate = parsedDate }
                endDate = parsedDate
            }

            if record.type == "session_meta" {
                sessionId = record.payload["id"]?.stringValue
                cwd = record.payload["cwd"]?.stringValue ?? cwd
            }

            if firstUserMessage == nil, record.type == "response_item" {
                if record.payload["role"]?.stringValue == "user",
                   let content = record.payload["content"],
                   let message = extractText(from: content) {
                    firstUserMessage = message
                }
            }
        }

        guard let id = sessionId, let start = startDate, let end = endDate else { return nil }
        let title = truncated(firstUserMessage ?? "(no user message)", limit: 60)
        return SessionSummary(id: id, startDate: start, endDate: end, cwd: cwd, title: title)
    }

    static func loadMessages(from url: URL) throws -> [SessionMessage] {
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

    static func findSessionFile(id: String) throws -> URL {
        for url in allSessionFiles() {
            if let summary = try loadSummary(from: url), summary.id == id {
                return url
            }
        }
        throw SessionError.sessionNotFound(id)
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
}

private func truncated(_ text: String, limit: Int) -> String {
    guard text.count > limit, limit > 3 else { return text }
    let endIndex = text.index(text.startIndex, offsetBy: limit - 3)
    return String(text[..<endIndex]) + "..."
}

@main
struct CodexSessions: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "codex-sessions",
        abstract: "Browse Codex session logs.",
        subcommands: [List.self, Show.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List sessions under a date path.")

        @Argument(help: "Relative date path like 2026/01/08, 2026/01, or 2026")
        var path: String

        mutating func run() throws {
            let files = try SessionLoader.sessionFiles(under: path)
            let summaries = try files.compactMap { try SessionLoader.loadSummary(from: $0) }
                .sorted { $0.startDate < $1.startDate }

            if summaries.isEmpty {
                print("No sessions found for \(path).")
                return
            }

            for summary in summaries {
                let start = TimestampParser.format(summary.startDate)
                let end = TimestampParser.format(summary.endDate)
                let line = "\(summary.id) | \(start) -> \(end) | \(summary.cwd) | \(summary.title)"
                print(line)
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a session by ID.")

        @Argument(help: "Session ID to display")
        var sessionId: String

        mutating func run() throws {
            let fileURL = try SessionLoader.findSessionFile(id: sessionId)
            let messages = try SessionLoader.loadMessages(from: fileURL)

            if messages.isEmpty {
                print("No messages found for session \(sessionId).")
                return
            }

            for message in messages {
                let timestamp = TimestampParser.format(message.timestamp)
                let role = message.role.capitalized
                print("[\(timestamp)] \(role): \(message.text)")
            }
        }
    }
}
