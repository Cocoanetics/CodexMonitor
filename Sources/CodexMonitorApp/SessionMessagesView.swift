import SwiftUI
import AppKit
import CodexCore

@MainActor
final class SessionMessagesViewModel: ObservableObject {
    @Published var summary: SessionSummary?
    @Published var messages: [SessionMessage] = []
    @Published var errorMessage: String?
    @Published var isLoading: Bool = false

    private var currentURL: URL?

    func load(url: URL?) {
        guard let url else {
            currentURL = nil
            summary = nil
            messages = []
            errorMessage = nil
            isLoading = false
            return
        }
        currentURL = url
        summary = nil
        messages = []
        errorMessage = nil
        isLoading = true

        let requestedURL = url
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let summary = try SessionLoader.loadSummary(from: requestedURL)
                    let messages = try SessionLoader.loadMessages(from: requestedURL)
                    return (summary, messages)
                }.value
                guard self.currentURL == requestedURL else { return }
                self.summary = result.0
                self.messages = result.1
                self.errorMessage = nil
                self.isLoading = false
            } catch {
                guard self.currentURL == requestedURL else { return }
                self.errorMessage = String(describing: error)
                self.isLoading = false
            }
        }
    }
}

struct SessionMessagesView: View {
    @EnvironmentObject private var sessionModel: SessionViewModel
    @StateObject private var model = SessionMessagesViewModel()

    var body: some View {
        let sessionURL = sessionModel.selectedSession?.url
        VStack(spacing: 0) {
            if sessionURL == nil {
                Text("No session selected.")
                    .frame(minWidth: 560, minHeight: 480)
            } else {
                SessionHeaderView(summary: model.summary)
                    .padding()

                Divider()

                if model.isLoading {
                    SessionLoadingPlaceholder()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if let error = model.errorMessage {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .cornerRadius(8)
                            }

                            ForEach(model.messages.indices, id: \.self) { index in
                                SessionMessageRow(message: model.messages[index])
                                    .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .onAppear {
            model.load(url: sessionURL)
        }
        .onChange(of: sessionURL) { _, newValue in
            model.load(url: newValue)
        }
        .toolbar {
            Button {
                model.load(url: sessionURL)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(sessionURL == nil)
        }
    }
}

private struct SessionHeaderView: View {
    let summary: SessionSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary?.title ?? "Session")
                .font(.headline)
            if let summary {
                let project = SessionUtils.projectName(from: summary.cwd)
                Text("\(project) • \(summary.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SessionLoadingPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Loading session…")
                .font(.headline)
            Text("No content yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}

private struct SessionMessageRow: View {
    let message: SessionMessage

    var body: some View {
        let displayText = displayedText(for: message)
        VStack(alignment: .leading, spacing: 8) {
            SessionMessageHeader(role: message.role, timestamp: message.timestamp) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            }
            MarkdownTextView(displayText)
                .font(.body)
                .foregroundStyle(.primary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor ?? Color.clear, lineWidth: borderColor == nil ? 0 : 1)
        )
    }

    private var backgroundColor: Color {
        switch message.role.lowercased() {
        case "user":
            return Color(nsColor: .systemBlue).opacity(0.08)
        case "assistant":
            return Color(nsColor: .controlBackgroundColor).opacity(0.85)
        case "system":
            return Color(nsColor: .systemOrange).opacity(0.08)
        case "tool", "function":
            return Color(nsColor: .systemGreen).opacity(0.08)
        default:
            return Color(nsColor: .controlBackgroundColor)
        }
    }

    private var borderColor: Color? {
        message.role.lowercased() == "assistant"
            ? Color(nsColor: .separatorColor)
            : nil
    }

    private func displayedText(for message: SessionMessage) -> String {
        guard message.role.lowercased() == "user" else { return message.text }
        let text = message.text
        let startsWithContext = text.hasPrefix("# Context from my IDE setup:")
            || text.hasPrefix("Context from my IDE setup:")
        guard startsWithContext else { return message.text }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if let markerIndex = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "My request for Codex:" || trimmed == "## My request for Codex:"
        }) {
            let start = markerIndex + 1
            let remainingLines = Array(lines.dropFirst(start))
            if let nextContextIndex = remainingLines.firstIndex(where: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed == "Context from my IDE setup:" || trimmed == "# Context from my IDE setup:"
            }) {
                let slice = remainingLines.prefix(nextContextIndex)
                return slice.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return remainingLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return message.text
    }
}

private struct SessionMessageHeader: View {
    let role: String
    let timestamp: Date
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(roleDisplayName, systemImage: roleIconName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(TimestampParser.format(timestamp))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy markdown")
        }
    }

    private var roleDisplayName: String {
        let trimmed = role.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown" }
        return trimmed.capitalized
    }

    private var roleIconName: String {
        switch role.lowercased() {
        case "user":
            return "person"
        case "assistant":
            return "cpu"
        case "system":
            return "gear"
        case "tool", "function":
            return "wrench.and.screwdriver"
        default:
            return "bubble.left.and.bubble.right"
        }
    }
}
