import Foundation

public enum SessionUtils {
    public static func normalizeWhitespace(_ text: String) -> String {
        let replaced = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return replaced.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func stripFilePaths(from text: String) -> String {
        let pattern = "/Users/[^\\s]+?\\.[A-Za-z0-9]+(?::\\d+(?::\\d+)?)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    public static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 3 else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: limit - 3)
        return String(text[..<endIndex]) + "..."
    }
    
    public static func stripInstructionsBlock(from text: String) -> String {
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
    
    public static func projectName(from cwd: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown" }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    public static func originatorDisplayName(from originator: String, limit: Int = 24) -> String {
        let trimmed = originator.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown" }
        let lowercased = trimmed.lowercased()
        if lowercased == "codex_vscode" {
            return "VS.CODE"
        }
        if lowercased == "codex_cli" || lowercased == "codex_tui" {
            return "CLI"
        }
        var display = trimmed
        if trimmed.contains("/") {
            let last = URL(fileURLWithPath: trimmed).lastPathComponent
            if !last.isEmpty { display = last }
        } else if trimmed.contains(".") {
            if let last = trimmed.split(separator: ".").last, !last.isEmpty {
                display = String(last)
            }
        } else if trimmed.contains(":") {
            if let last = trimmed.split(separator: ":").last, !last.isEmpty {
                display = String(last)
            }
        }
        let normalized = normalizeWhitespace(display)
        return truncated(normalized, limit: limit)
    }
}
