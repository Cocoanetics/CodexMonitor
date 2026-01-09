import SwiftUI

struct MarkdownTextView: View {
    private struct MarkdownBlock {
        let text: String
        let isCodeBlock: Bool
        let headingLevel: Int?
        let isDivider: Bool
    }

    private enum RenderBlock {
        case markdown(String)
        case xml(tag: String, content: String)
    }

    let markdown: String
    let baseFont: Font
    let foregroundStyle: AnyShapeStyle
    let textSelection: Bool
    let paragraphSpacing: CGFloat?
    let collapseXML: Bool

    @ScaledMetric(relativeTo: .body) private var defaultParagraphSpacing: CGFloat = 10

    init(
        _ markdown: String,
        baseFont: Font = .body,
        foregroundStyle: AnyShapeStyle = AnyShapeStyle(.primary),
        textSelection: Bool = true,
        paragraphSpacing: CGFloat? = nil,
        collapseXML: Bool = true
    ) {
        self.markdown = markdown
        self.baseFont = baseFont
        self.foregroundStyle = foregroundStyle
        self.textSelection = textSelection
        self.paragraphSpacing = paragraphSpacing
        self.collapseXML = collapseXML
    }

    var body: some View {
        let segments = renderBlocks(from: markdown)
        VStack(alignment: .leading, spacing: paragraphSpacing ?? defaultParagraphSpacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .markdown(let text):
                    let blocks = markdownBlocks(from: text)
                    VStack(alignment: .leading, spacing: paragraphSpacing ?? defaultParagraphSpacing) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            if block.isDivider {
                                Divider()
                            } else {
                                let font = block.isCodeBlock ? .system(.body, design: .monospaced) : fontForBlock(block)
                                let styledText = displayText(for: block)
                                    .font(font)
                                    .foregroundStyle(foregroundStyle)
                                if block.isCodeBlock {
                                    selectable(styledText)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(nsColor: .controlBackgroundColor))
                                        .cornerRadius(6)
                                        .padding(.bottom, -4)
                                } else {
                                    selectable(styledText)
                                }
                            }
                        }
                    }
                case .xml(let tag, let content):
                    DisclosureGroup {
                        MarkdownTextView(
                            content,
                            baseFont: baseFont,
                            foregroundStyle: foregroundStyle,
                            textSelection: textSelection,
                            paragraphSpacing: paragraphSpacing,
                            collapseXML: false
                        )
                    } label: {
                        Text("[\(displayTagName(tag))]")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func selectable(_ text: Text) -> some View {
        if textSelection {
            text.textSelection(.enabled)
        } else {
            text.textSelection(.disabled)
        }
    }

    private func markdownBlocks(from text: String) -> [MarkdownBlock] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var currentLines: [String] = []
        var inCodeFence = false

        func flushBlock(isCodeBlock: Bool) {
            guard !currentLines.isEmpty else { return }
            let joined = currentLines.joined(separator: "\n")
            let trimmed = isCodeBlock ? trimTrailingNewlines(in: joined) : joined.trimmingCharacters(in: .whitespacesAndNewlines)
            currentLines.removeAll()
            guard !trimmed.isEmpty else { return }
            if isCodeBlock {
                blocks.append(MarkdownBlock(text: trimmed, isCodeBlock: true, headingLevel: nil, isDivider: false))
                return
            }

            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let firstLineIndex = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if let firstLineIndex {
                let firstLine = lines[firstLineIndex].trimmingCharacters(in: .whitespaces)
                if let headingLevel = headingLevel(in: firstLine) {
                    blocks.append(MarkdownBlock(text: firstLine, isCodeBlock: false, headingLevel: headingLevel, isDivider: false))
                    let remainder = lines.dropFirst(firstLineIndex + 1)
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remainder.isEmpty {
                        blocks.append(MarkdownBlock(text: remainder, isCodeBlock: false, headingLevel: nil, isDivider: false))
                    }
                    return
                }
            }

            blocks.append(MarkdownBlock(text: trimmed, isCodeBlock: false, headingLevel: nil, isDivider: false))
        }

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") {
                if inCodeFence {
                    flushBlock(isCodeBlock: true)
                    inCodeFence = false
                } else {
                    flushBlock(isCodeBlock: false)
                    inCodeFence = true
                }
                continue
            }

            if inCodeFence {
                currentLines.append(line)
                continue
            }

            if trimmedLine == "---" {
                flushBlock(isCodeBlock: false)
                blocks.append(MarkdownBlock(text: "", isCodeBlock: false, headingLevel: nil, isDivider: true))
                continue
            }

            if trimmedLine.isEmpty {
                flushBlock(isCodeBlock: false)
            } else {
                currentLines.append(line)
            }
        }

        flushBlock(isCodeBlock: inCodeFence)
        return blocks
    }

    private func trimTrailingNewlines(in text: String) -> String {
        var result = text
        while result.last == "\n" || result.last == "\r" {
            result.removeLast()
        }
        return result
    }

    private func renderBlocks(from text: String) -> [RenderBlock] {
        guard collapseXML else {
            return [.markdown(text)]
        }
        var blocks: [RenderBlock] = []
        var remaining = text

        while let startRange = remaining.range(of: "<") {
            let prefix = String(remaining[..<startRange.lowerBound])
            if !prefix.isEmpty {
                blocks.append(.markdown(prefix))
            }

            let afterStart = remaining[startRange.lowerBound...]
            guard let closeBracket = afterStart.firstIndex(of: ">") else {
                blocks.append(.markdown(String(afterStart)))
                return blocks
            }

            let tagName = String(afterStart[afterStart.index(after: afterStart.startIndex)..<closeBracket])
            if !isSimpleTagName(tagName) {
                blocks.append(.markdown(String(remaining[startRange.lowerBound..<remaining.index(after: startRange.lowerBound)])))
                remaining = String(remaining[remaining.index(after: startRange.lowerBound)...])
                continue
            }

            let closingTag = "</\(tagName)>"
            guard let closeRange = remaining.range(of: closingTag, range: closeBracket..<remaining.endIndex) else {
                blocks.append(.markdown(String(afterStart)))
                return blocks
            }

            let contentStart = remaining.index(after: closeBracket)
            let content = String(remaining[contentStart..<closeRange.lowerBound])
            blocks.append(.xml(tag: tagName, content: content))
            remaining = String(remaining[closeRange.upperBound...])
        }

        if !remaining.isEmpty {
            blocks.append(.markdown(remaining))
        }
        return blocks
    }

    private func renderedText(for block: MarkdownBlock, escapeAngleBrackets: Bool) -> String {
        let base = block.isCodeBlock
            ? block.text
            : (escapeAngleBrackets ? block.text : renderedMarkdownText(block.text))
        guard escapeAngleBrackets, !block.isCodeBlock else { return base }
        return base
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func displayText(for block: MarkdownBlock) -> Text {
        let hasList = containsListMarker(in: block.text)
        if hasList && !block.isCodeBlock {
            let adjusted = adjustListSpacing(in: block.text)
            var listText = replaceListMarkers(in: adjusted)
            if !collapseXML {
                listText = escapeAngleBrackets(in: listText)
            }
            let rendered = markdownPreservingLineBreaks(in: listText)
            return textView(from: rendered)
        }
        let rendered = renderedText(for: block, escapeAngleBrackets: !collapseXML)
        return textView(from: rendered)
    }

    private func renderedMarkdownText(_ text: String) -> String {
        let adjusted = adjustListSpacing(in: text)
        return markdownPreservingLineBreaks(in: adjusted)
    }

    private func containsListMarker(in text: String) -> Bool {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                return true
            }
            var index = trimmed.startIndex
            while index < trimmed.endIndex, trimmed[index].isNumber {
                index = trimmed.index(after: index)
            }
            if index < trimmed.endIndex,
               (trimmed[index] == "." || trimmed[index] == ")"),
               trimmed.index(after: index) < trimmed.endIndex,
               trimmed[trimmed.index(after: index)] == " " {
                return true
            }
        }
        return false
    }

    private func adjustListSpacing(in text: String) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var result: [String] = []

        func isListLine(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                return true
            }
            var index = trimmed.startIndex
            while index < trimmed.endIndex, trimmed[index].isNumber {
                index = trimmed.index(after: index)
            }
            if index < trimmed.endIndex,
               (trimmed[index] == "." || trimmed[index] == ")"),
               trimmed.index(after: index) < trimmed.endIndex,
               trimmed[trimmed.index(after: index)] == " " {
                return true
            }
            return false
        }

        var lastNonEmptyWasText = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                result.append(line)
                lastNonEmptyWasText = false
                continue
            }

            let isList = isListLine(line)
            if isList && lastNonEmptyWasText {
                result.append("")
            }
            result.append(line)

            lastNonEmptyWasText = !isList
        }

        return result.joined(separator: "\n")
    }

    private func replaceListMarkers(in text: String) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let converted = lines.map { line -> String in
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                let content = trimmed.dropFirst(2)
                return "\(leading)• \(content)"
            }
            return line
        }
        return converted.joined(separator: "\n")
    }

    private func escapeAngleBrackets(in text: String) -> String {
        text
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func isSimpleTagName(_ tag: String) -> Bool {
        guard !tag.isEmpty else { return false }
        for scalar in tag.unicodeScalars {
            if !(CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-") {
                return false
            }
        }
        return true
    }

    private func displayTagName(_ tag: String) -> String {
        let lowercased = tag.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return lowercased.lowercased()
    }

    private func textView(from markdown: String) -> Text {
        if let attributed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)) {
            return Text(applyInlineCodeFont(to: attributed))
        }
        return Text(markdown)
    }

    private func applyInlineCodeFont(to attributed: AttributedString) -> AttributedString {
        var updated = attributed
        for run in updated.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                updated[run.range].font = .system(.body, design: .monospaced)
            }
        }
        return updated
    }

    private func markdownPreservingLineBreaks(in text: String) -> String {
        var result = ""
        var newlineCount = 0

        func flushNewlines(_ count: inout Int) {
            guard count > 0 else { return }
            if count == 1 {
                result.append("  \n")
            } else {
                result.append(String(repeating: "\n", count: count))
            }
            count = 0
        }

        for character in text {
            if character == "\n" {
                newlineCount += 1
            } else {
                flushNewlines(&newlineCount)
                result.append(character)
            }
        }

        flushNewlines(&newlineCount)

        return result
    }

    private func headingLevel(in line: String) -> Int? {
        var count = 0
        for character in line {
            if character == "#" {
                count += 1
            } else {
                break
            }
        }
        guard count > 0, count <= 6 else { return nil }
        let index = line.index(line.startIndex, offsetBy: count)
        guard index < line.endIndex, line[index] == " " else { return nil }
        return count
    }

    private func fontForBlock(_ block: MarkdownBlock) -> Font {
        guard let level = block.headingLevel else { return baseFont }
        switch level {
        case 1:
            return .title
        case 2:
            return .title2
        case 3:
            return .title3
        case 4:
            return .headline
        case 5:
            return .subheadline
        default:
            return .callout
        }
    }
}
