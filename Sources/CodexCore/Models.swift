import Foundation

public enum SessionError: Error, CustomStringConvertible {
    case invalidRoot(String)
    case sessionNotFound(String)
    case malformedRecord(String)
    case invalidWatchTarget(String)

    public var description: String {
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

public enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case object([String: JSONValue])
    case array([JSONValue])
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
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

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

public struct SessionRecord: Decodable {
    public let timestamp: String
    public let type: String
    public let payload: [String: JSONValue]
    
    public init(timestamp: String, type: String, payload: [String: JSONValue]) {
        self.timestamp = timestamp
        self.type = type
        self.payload = payload
    }
}

public struct SessionSummary: Sendable {
    public let id: String
    public let startDate: Date
    public let endDate: Date
    public let cwd: String
    public let title: String
    public let originator: String
    public let messageCount: Int
    
    public init(id: String, startDate: Date, endDate: Date, cwd: String, title: String, originator: String, messageCount: Int) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.cwd = cwd
        self.title = title
        self.originator = originator
        self.messageCount = messageCount
    }
}

public struct SessionMessage: Sendable {
    public let role: String
    public let timestamp: Date
    public let text: String
    
    public init(role: String, timestamp: Date, text: String) {
        self.role = role
        self.timestamp = timestamp
        self.text = text
    }
}

public struct SessionMessageExport: Encodable {
    public let role: String
    public let timestamp: Date
    public let text: String
    
    public init(role: String, timestamp: Date, text: String) {
        self.role = role
        self.timestamp = timestamp
        self.text = text
    }
}

public struct FileIdentity: Hashable {
    public let device: UInt64
    public let inode: UInt64
    
    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct SessionSummaryExport: Encodable {
    public let id: String
    public let start: Date
    public let end: Date
    public let cwd: String
    public let title: String
    public let originator: String
    public let messageCount: Int
    
    public init(id: String, start: Date, end: Date, cwd: String, title: String, originator: String, messageCount: Int) {
        self.id = id
        self.start = start
        self.end = end
        self.cwd = cwd
        self.title = title
        self.originator = originator
        self.messageCount = messageCount
    }
}

public struct SessionExport: Encodable {
    public let summary: SessionSummaryExport?
    public let messages: [SessionMessageExport]
    
    public init(summary: SessionSummaryExport?, messages: [SessionMessageExport]) {
        self.summary = summary
        self.messages = messages
    }
}
