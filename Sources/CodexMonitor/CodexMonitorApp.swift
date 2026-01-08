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
            if model.activeSessions.isEmpty {
                Text("No active sessions")
            } else {
                ForEach(model.activeSessions) { session in
                    Button {
                        // Action could open the file or something useful
                        NSWorkspace.shared.open(session.url)
                    } label: {
                        SessionRow(session: session, now: model.now)
                    }
                }
            }
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            let icon = model.activeSessions.isEmpty
                ? "bubble.left.and.bubble.right"
                : "bubble.left.and.bubble.right.fill"
            Image(systemName: icon)
        }
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
