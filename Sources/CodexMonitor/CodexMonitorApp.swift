import SwiftUI
import CodexCore
import Logging
#if canImport(OSLog)
import OSLog
#endif

@main
struct CodexMonitorApp: App {
    @StateObject private var model = SessionViewModel()

    init() {
        Self.configureLogging()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: model)
        } label: {
            let icon = model.activeSessions.isEmpty
                ? "bubble.left.and.bubble.right"
                : "bubble.left.and.bubble.right.fill"
            Image(systemName: icon)
        }
        .menuBarExtraStyle(.menu)
        WindowGroup(id: "session") {
            SessionMessagesView()
                .environmentObject(model)
        }
        .handlesExternalEvents(matching: ["session"])
    }

    private static func configureLogging() {
        #if canImport(OSLog)
        LoggingSystem.bootstrap { label in
            let category = label.split(separator: ".").last?.description ?? "default"
            let osLogger = OSLog(subsystem: "com.cocoanetics.codex-monitor", category: category)
            var handler = OSLogHandler(label: label, log: osLogger)
            handler.logLevel = .info
            return handler
        }
        #else
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        #endif
    }
}

private struct MenuBarContentView: View {
    @ObservedObject var model: SessionViewModel

    var body: some View {
        if model.todaySessions.isEmpty {
            Text("No sessions yet today")
        } else {
            ForEach(model.todaySessions) { session in
                Button {
                    openSession(session)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.isActive(session) ? "circle.fill" : "circle")
                            .imageScale(.small)
                            .foregroundStyle(model.isActive(session) ? .green : .secondary)
                        Text(sessionLabel(session))
                    }
                }
            }
        }
        Divider()
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func openSession(_ session: SessionViewModel.TodaySession) {
        NSApp.activate(ignoringOtherApps: true)
        model.selectSession(summary: SessionSummary(
            id: session.id,
            startDate: session.startDate,
            endDate: session.endDate,
            cwd: session.cwd,
            title: session.title,
            originator: session.originator,
            messageCount: 0
        ), url: session.url)
        SessionWindowController.shared.show(model: model)
    }

    private func sessionLabel(_ session: SessionViewModel.TodaySession) -> String {
        let age = relativeAgeString(since: session.endDate, now: model.now)
        return "\(session.project) | \(age)"
    }
}

private struct SessionRow: View {
    let session: SessionViewModel.ActiveSession
    let now: Date

    var body: some View {
        let age = relativeAgeString(since: session.lastModified, now: now)
        let originator = SessionUtils.originatorDisplayName(from: session.originator)
        Text("\(session.project) | \(originator) | \(age)")
    }
}

private func relativeAgeString(since date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 {
        return "\(seconds)s ago"
    }
    let minutes = seconds / 60
    let remainingSeconds = seconds % 60
    if minutes < 60 {
        return "\(minutes)m \(remainingSeconds)s ago"
    }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    if hours < 24 {
        return "\(hours)h \(remainingMinutes)m ago"
    }
    let days = hours / 24
    let remainingHours = hours % 24
    return "\(days)d \(remainingHours)h ago"
}
