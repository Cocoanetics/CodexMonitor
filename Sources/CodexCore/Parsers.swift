import Foundation

public enum TimestampParser {
    public static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: string)
    }

    public static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    public static func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    public static func formatShortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

public enum RangeParser {
    public struct ParseError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func parse(_ input: String) throws -> [ClosedRange<Int>] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        var ranges: [ClosedRange<Int>] = []
        for part in trimmed.split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty { continue }
            if token.contains("...") {
                let bounds = token.components(separatedBy: "...")
                guard bounds.count == 2 else {
                    throw ParseError(message: "Invalid range segment: \(token)")
                }
                let start = bounds[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let end = bounds[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard let lower = Int(start), let upper = Int(end), lower >= 1, upper >= 1 else {
                    throw ParseError(message: "Invalid range numbers: \(token)")
                }
                let ordered = lower <= upper ? lower...upper : upper...lower
                ranges.append(ordered)
            } else {
                guard let value = Int(token), value >= 1 else {
                    throw ParseError(message: "Invalid message index: \(token)")
                }
                ranges.append(value...value)
            }
        }
        return ranges
    }
}
