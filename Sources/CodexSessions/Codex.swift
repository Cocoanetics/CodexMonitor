import ArgumentParser
import CoreServices
import Foundation
import Darwin
import Logging
#if canImport(OSLog)
import OSLog
#endif

private enum SessionError: Error, CustomStringConvertible {
    case invalidRoot(String)
    case sessionNotFound(String)
    case malformedRecord(String)
    case invalidWatchTarget(String)

    var description: String {
        switch self {
        case .invalidRoot(let path):
            return "Invalid sessions path: \(path)"
        case .sessionNotFound(let id):
            return "Session not found: \(id)"
        case .malformedRecord(let detail):
            return "Malformed record: \(detail)"
        case .invalidWatchTarget(let path):
            return "Invalid watch path: \(path)"
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
    let originator: String
    let messageCount: Int
}

private struct SessionMessage {
    let role: String
    let timestamp: Date
    let text: String
}

private struct SessionMessageExport: Encodable {
    let role: String
    let timestamp: String
    let text: String
}

private struct FileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
}

private struct SessionSummaryExport: Encodable {
    let id: String
    let start: String
    let end: String
    let cwd: String
    let title: String
    let originator: String
    let messageCount: Int
}

private struct SessionExport: Encodable {
    let summary: SessionSummaryExport?
    let messages: [SessionMessageExport]
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

    static func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func formatShortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

private enum RangeParser {
    static func parse(_ input: String) throws -> [ClosedRange<Int>] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        var ranges: [ClosedRange<Int>] = []
        for part in trimmed.split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty { continue }
            if token.contains("...") {
                let bounds = token.components(separatedBy: "...")
                guard bounds.count == 2 else {
                    throw ValidationError("Invalid range segment: \(token)")
                }
                let start = bounds[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let end = bounds[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard let lower = Int(start), let upper = Int(end), lower >= 1, upper >= 1 else {
                    throw ValidationError("Invalid range numbers: \(token)")
                }
                let ordered = lower <= upper ? lower...upper : upper...lower
                ranges.append(ordered)
            } else {
                guard let value = Int(token), value >= 1 else {
                    throw ValidationError("Invalid message index: \(token)")
                }
                ranges.append(value...value)
            }
        }
        return ranges
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

    static func sessionFilesSnapshot(under relativePath: String?) throws -> [URL: Date] {
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

    static func sessionFileSnapshot(for url: URL) throws -> Date? {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        return values.contentModificationDate
    }

    static func fileIdentity(for url: URL) -> FileIdentity? {
        var info = stat()
        if stat(url.path, &info) == 0 {
            return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
        }
        return nil
    }

    static func loadSummary(from url: URL) throws -> SessionSummary? {
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
        let cleaned = stripFilePaths(from: titleText)
        let flattened = normalizeWhitespace(cleaned)
        let title = truncated(flattened, limit: 200)
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
}

private func isSkippableUserMessage(_ text: String) -> Bool {
    let prefixes = [
        "# AGENTS.md instructions",
        "<environment_context>"
    ]
    return prefixes.contains { text.hasPrefix($0) }
}

private func extractUserTitle(from text: String) -> String? {
    if isSkippableUserMessage(text) {
        return nil
    }
    if let request = extractRequestSection(from: text) {
        return request
    }
    return text.isEmpty ? nil : text
}

private func extractRequestSection(from text: String) -> String? {
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

private func firstLine(of text: String) -> String {
    if let line = text.split(whereSeparator: \.isNewline).first {
        return String(line)
    }
    return text
}

private func normalizeWhitespace(_ text: String) -> String {
    let replaced = text.replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
    return replaced.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func stripFilePaths(from text: String) -> String {
    let pattern = "/Users/[^\\s]+?\\.[A-Za-z0-9]+(?::\\d+(?::\\d+)?)?"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return text
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
}

private func truncated(_ text: String, limit: Int) -> String {
    guard text.count > limit, limit > 3 else { return text }
    let endIndex = text.index(text.startIndex, offsetBy: limit - 3)
    return String(text[..<endIndex]) + "..."
}

private func projectName(from cwd: String) -> String {
    let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "Unknown" }
    return URL(fileURLWithPath: trimmed).lastPathComponent
}

private func formatSummaryLine(_ summary: SessionSummary) -> String {
    let start = TimestampParser.formatShortDateTime(summary.startDate)
    let end = TimestampParser.formatTime(summary.endDate)
    return "\(summary.id)\t\(start)->\(end)\t\(summary.cwd)\t\(summary.title)"
}

private func formatWatchLine(_ summary: SessionSummary) -> String {
    let start = TimestampParser.formatShortDateTime(summary.startDate)
    let end = TimestampParser.formatTime(summary.endDate)
    let project = projectName(from: summary.cwd)
    return "[\(project)] \(start)->\(end) \(summary.title) [\(summary.id)]"
}

private func messageMarkdown(_ message: SessionMessage) -> String {
    stripInstructionsBlock(from: message.text)
}

private func exportSummary(from summary: SessionSummary) -> SessionSummaryExport {
    SessionSummaryExport(
        id: summary.id,
        start: TimestampParser.format(summary.startDate),
        end: TimestampParser.format(summary.endDate),
        cwd: summary.cwd,
        title: summary.title,
        originator: summary.originator,
        messageCount: summary.messageCount
    )
}

private func exportMessages(from messages: [SessionMessage]) -> [SessionMessageExport] {
    messages.map { message in
        SessionMessageExport(
            role: message.role,
            timestamp: TimestampParser.format(message.timestamp),
            text: message.text
        )
    }
}

private func messageHeader(_ message: SessionMessage, index: Int) -> String {
    let role = message.role.capitalized
    let time = TimestampParser.format(message.timestamp)
    return "──── \(role) · \(time) · #\(index) ────"
}

private func selectMessages(_ messages: [SessionMessage], ranges: [ClosedRange<Int>]) -> [(Int, SessionMessage)] {
    let indexed = messages.enumerated().map { ($0 + 1, $1) }
    guard !ranges.isEmpty else { return indexed }
    return indexed.filter { position, _ in
        ranges.contains(where: { $0.contains(position) })
    }
}

private func stripInstructionsBlock(from text: String) -> String {
    var result = text
    let startTag = "<INSTRUCTIONS>"
    let endTag = "</INSTRUCTIONS>"

    while let startRange = result.range(of: startTag),
          let endRange = result.range(of: endTag, range: startRange.upperBound..<result.endIndex) {
        let removalRange = startRange.lowerBound..<endRange.upperBound
        result.removeSubrange(removalRange)
    }

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

private final class WatchState: @unchecked Sendable {
    private struct FileWatcher {
        let source: DispatchSourceFileSystemObject
        let fileDescriptor: Int32
        let identity: FileIdentity?
    }

    fileprivate enum UpdateReason {
        case fsevent
        case fileEvent
        case poll
    }

    var snapshot: [URL: Date]
    let watchedFile: URL?
    let activeWindow: TimeInterval
    var pendingWorkItem: DispatchWorkItem?
    private var pollTimer: DispatchSourceTimer?
    private var watchers: [URL: FileWatcher] = [:]
    private var cachedSummaries: [URL: SessionSummary] = [:]
    private let queue = DispatchQueue(label: "codex.sessions.watch")
    private let logger = Logger(label: "codex-sessions.watch")

    init(snapshot: [URL: Date], watchedFile: URL?, activeWindow: TimeInterval) {
        self.snapshot = snapshot
        self.watchedFile = watchedFile
        self.activeWindow = activeWindow
    }

    fileprivate func scheduleUpdate(reason: UpdateReason) {
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performSnapshotUpdate(reason: reason)
        }
        pendingWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func bootstrapWatchers() {
        queue.async { [weak self] in
            self?.performBootstrap()
        }
    }

    private func performBootstrap() {
        do {
            if let watchedFile {
                if installWatcher(for: watchedFile) {
                    try printActiveSession(for: watchedFile)
                }
                if let modified = try SessionLoader.sessionFileSnapshot(for: watchedFile) {
                    snapshot[watchedFile] = modified
                }
                return
            }

            let latest = try SessionLoader.sessionFilesSnapshot(under: nil)
            let activeCutoff = Date().addingTimeInterval(-activeWindow)
            for (url, modified) in latest where modified >= activeCutoff {
                if installWatcher(for: url) {
                    try printActiveSession(for: url)
                }
                snapshot[url] = modified
            }
        } catch {
            fputs("Watch error: \(error)\n", stderr)
        }
    }

    func startPolling(interval: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            self?.performSnapshotUpdate(reason: .poll)
        }
        timer.resume()
        pollTimer = timer
    }

    private func performSnapshotUpdate(reason: UpdateReason) {
        if watchedFile != nil, reason == .poll { return }
        do {
            switch reason {
            case .fsevent:
                try refreshWatchers()
                try printUpdatesForWatchedFiles(force: false)
            case .fileEvent:
                try printUpdatesForWatchedFiles(force: true)
            case .poll:
                try refreshWatchers()
            }
        } catch {
            fputs("Watch error: \(error)\n", stderr)
        }
    }

    private func refreshWatchers() throws {
        guard watchedFile == nil else { return }
        let latest = try SessionLoader.sessionFilesSnapshot(under: nil)
        let latestURLs = Set(latest.keys)
        let activeCutoff = Date().addingTimeInterval(-activeWindow)
        for (url, watcher) in watchers where !latestURLs.contains(url) {
            removeWatcher(watcher, url: url, printInactive: false)
        }
        for (url, modified) in latest where modified >= activeCutoff {
            let currentIdentity = SessionLoader.fileIdentity(for: url)
            if let watcher = watchers[url] {
                if watcher.identity != currentIdentity {
                    removeWatcher(watcher, url: url, printInactive: false)
                    if installWatcher(for: url) {
                        try printActiveSession(for: url)
                    }
                }
            } else {
                if installWatcher(for: url) {
                    try printActiveSession(for: url)
                }
            }
            snapshot[url] = modified
        }
        for (url, watcher) in watchers {
            if let modified = latest[url], modified < activeCutoff {
                removeWatcher(watcher, url: url, printInactive: true)
            }
        }
    }

    private func printUpdatesForWatchedFiles(force: Bool) throws {
        if let watchedFile {
            if force {
                try printUpdateForFileEvent(for: watchedFile)
            } else {
                try printUpdateIfNeeded(for: watchedFile)
            }
            return
        }
        for url in watchers.keys.sorted(by: { $0.path < $1.path }) {
            if force {
                try printUpdateForFileEvent(for: url)
            } else {
                try printUpdateIfNeeded(for: url)
            }
        }
    }

    private func printUpdateIfNeeded(for url: URL) throws {
        guard let modified = try SessionLoader.sessionFileSnapshot(for: url) else { return }
        let oldDate = snapshot[url]
        guard oldDate == nil || modified > oldDate! else { return }
        if let summary = try cacheSummaryIfNeeded(for: url) {
            let message = "Session modified: - \(formatWatchLine(summary))"
            print(message)
            logger.info("\(message)")
            snapshot[url] = summary.endDate
        } else {
            let message = "Session modified: - \(url.lastPathComponent)"
            print(message)
            logger.info("\(message)")
            snapshot[url] = modified
        }
    }

    private func printUpdateForFileEvent(for url: URL) throws {
        let eventTime = Date()
        if let summary = cachedSummaries[url] {
            let updated = SessionSummary(
                id: summary.id,
                startDate: summary.startDate,
                endDate: eventTime,
                cwd: summary.cwd,
                title: summary.title,
                originator: summary.originator,
                messageCount: summary.messageCount
            )
            cachedSummaries[url] = updated
            snapshot[url] = eventTime
            let message = "Session modified: - \(formatWatchLine(updated))"
            print(message)
            logger.info("\(message)")
            return
        }
        if let summary = try cacheSummaryIfNeeded(for: url) {
            snapshot[url] = summary.endDate
            let message = "Session modified: - \(formatWatchLine(summary))"
            print(message)
            logger.info("\(message)")
        } else {
            snapshot[url] = eventTime
            let message = "Session modified: - \(url.lastPathComponent)"
            print(message)
            logger.info("\(message)")
        }
    }

    private func cacheSummaryIfNeeded(for url: URL) throws -> SessionSummary? {
        if let summary = cachedSummaries[url] {
            return summary
        }
        if let summary = try SessionLoader.loadSummary(from: url) {
            cachedSummaries[url] = summary
            return summary
        }
        return nil
    }

    private func installWatcher(for url: URL) -> Bool {
        guard watchers[url] == nil else { return false }
        let fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleUpdate(reason: .fileEvent)
        }
        source.setCancelHandler {
            close(fileDescriptor)
        }
        source.resume()
        let identity = SessionLoader.fileIdentity(for: url)
        watchers[url] = FileWatcher(source: source, fileDescriptor: fileDescriptor, identity: identity)
        return true
    }

    private func removeWatcher(_ watcher: FileWatcher, url: URL, printInactive: Bool) {
        if printInactive, let summary = cachedSummaries[url] {
            let message = "Session inactive: \(formatWatchLine(summary))"
            print(message)
            logger.info("\(message)")
        }
        watcher.source.cancel()
        watchers.removeValue(forKey: url)
        snapshot.removeValue(forKey: url)
        cachedSummaries.removeValue(forKey: url)
    }

    private func printActiveSession(for url: URL) throws {
        if let summary = try cacheSummaryIfNeeded(for: url) {
            let message = "Session active: \(formatWatchLine(summary))"
            print(message)
            logger.info("\(message)")
        } else {
            let message = "Session active: \(url.lastPathComponent)"
            print(message)
            logger.info("\(message)")
        }
    }
}

private func fseventsCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientInfo: UnsafeMutableRawPointer?,
    _ eventCount: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientInfo else { return }
    let state = Unmanaged<WatchState>.fromOpaque(clientInfo).takeUnretainedValue()
    state.scheduleUpdate(reason: .fsevent)
}

@main
struct CodexSessions: ParsableCommand {
    static func main() {
        #if canImport(OSLog)
        LoggingSystem.bootstrap { label in
            let category = label.split(separator: ".").last?.description ?? "default"
            let osLogger = OSLog(subsystem: "com.cocoanetics.codex-sessions", category: category)
            var handler = OSLogHandler(label: label, log: osLogger)
            handler.logLevel = .info
            return handler
        }
        #else
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        #endif
        do {
            var command = try CodexSessions.parseAsRoot()
            try command.run()
        } catch {
            CodexSessions.exit(withError: error)
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "codex-sessions",
        abstract: "Browse Codex session logs.",
        subcommands: [List.self, Show.self, Watch.self]
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
                print(formatSummaryLine(summary))
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a session by ID.")

        @Argument(help: "Session ID to display")
        var sessionId: String

        @Flag(name: .long, help: "Output session as pretty JSON")
        var json: Bool = false

        @Option(name: .long, help: "Message ranges like 1...3,25...28")
        var ranges: String?

        mutating func run() throws {
            let fileURL = try SessionLoader.findSessionFile(id: sessionId)
            let messages = try SessionLoader.loadMessages(from: fileURL)

            if messages.isEmpty {
                print("No messages found for session \(sessionId).")
                return
            }

            let selected: [(Int, SessionMessage)]
            if let ranges = ranges {
                let parsed = try RangeParser.parse(ranges)
                selected = selectMessages(messages, ranges: parsed)
            } else {
                selected = selectMessages(messages, ranges: [])
            }

            if selected.isEmpty {
                print("No messages matched the requested ranges for session \(sessionId).")
                return
            }

            if json {
                let summary = try SessionLoader.loadSummary(from: fileURL)
                let export = SessionExport(
                    summary: summary.map(exportSummary),
                    messages: exportMessages(from: selected.map { $0.1 })
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(export)
                if let jsonString = String(data: data, encoding: .utf8) {
                    print(jsonString)
                }
                return
            }

            for (index, entry) in selected.enumerated() {
                let position = entry.0
                let message = entry.1
                if index > 0 { print("") }
                print(messageHeader(message, index: position))
                print(messageMarkdown(message))
            }
        }
    }

    struct Watch: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Watch sessions for new or updated files.")

        @Option(name: .long, help: "Watch a specific session id.")
        var session: String?

        mutating func run() throws {
            let activeWindow: TimeInterval = 30
            let state: WatchState
            let targetURL: URL

            if let session {
                let fileURL = try SessionLoader.findSessionFile(id: session)
                guard fileURL.pathExtension == "jsonl" else {
                    throw SessionError.invalidWatchTarget(fileURL.path)
                }
                let watchRoot = fileURL.deletingLastPathComponent()
                guard FileManager.default.fileExists(atPath: watchRoot.path) else {
                    throw SessionError.invalidWatchTarget(watchRoot.path)
                }
                print("Watching \(fileURL.path) for session changes...")
                state = WatchState(snapshot: [:], watchedFile: fileURL, activeWindow: activeWindow)
                targetURL = watchRoot
            } else {
                targetURL = SessionLoader.sessionsRoot

                guard FileManager.default.fileExists(atPath: targetURL.path) else {
                    throw SessionError.invalidWatchTarget(targetURL.path)
                }

                print("Watching \(targetURL.path) for session changes...")
                state = WatchState(snapshot: [:], watchedFile: nil, activeWindow: activeWindow)
            }
            let callback: FSEventStreamCallback = fseventsCallback

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(state).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            let pathsToWatch = [targetURL.path] as CFArray
            let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                pathsToWatch,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.2,
                flags
            ) else {
                throw SessionError.invalidWatchTarget(targetURL.path)
            }

            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global())
            guard FSEventStreamStart(stream) else {
                throw SessionError.invalidWatchTarget(targetURL.path)
            }

            state.bootstrapWatchers()
            state.startPolling(interval: 30.0)
            dispatchMain()
        }
    }
}
