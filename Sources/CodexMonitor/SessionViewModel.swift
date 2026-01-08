import Foundation
import CodexCore
import Combine
import Logging

@MainActor
class SessionViewModel: ObservableObject {
    struct ActiveSession: Identifiable, Equatable {
        let id: String
        let title: String
        let project: String
        let originator: String
        let lastModified: Date
        let url: URL
        
        static func == (lhs: ActiveSession, rhs: ActiveSession) -> Bool {
            lhs.id == rhs.id && lhs.lastModified == rhs.lastModified
        }
    }

    @Published var activeSessions: [ActiveSession] = []
    @Published var now: Date = Date()
    private var watcher: SessionWatcher?
    private var sessionsByURL: [URL: ActiveSession] = [:]
    private let logger = Logger(label: "codex-monitor.sessions")
    private var clockTask: Task<Void, Never>?

    init() {
        startWatching()
    }

    func startWatching() {
        startClock()
        let watcher = SessionWatcher(watchedFile: nil, activeWindow: 30)
        self.watcher = watcher
        
        watcher.onSessionActive = { [weak self] url, summary in
            Task { @MainActor [weak self] in
                self?.logSessionEvent(prefix: "Session active:", url: url, summary: summary)
                self?.updateSession(url: url, summary: summary)
            }
        }
        
        watcher.onSessionModified = { [weak self] url, summary in
            Task { @MainActor [weak self] in
                self?.logSessionEvent(prefix: "Session modified:", url: url, summary: summary)
                self?.updateSession(url: url, summary: summary)
            }
        }
        
        watcher.onSessionInactive = { [weak self] url, summary in
             Task { @MainActor [weak self] in
                self?.logSessionEvent(prefix: "Session inactive:", url: url, summary: summary)
                self?.removeSession(url: url)
            }
        }
        
        watcher.onError = { [weak self] error in
            self?.logger.error("Monitor error: \(String(describing: error))")
        }
        
        try? watcher.start()
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    self?.now = Date()
                }
            }
        }
    }
    
    private func updateSession(url: URL, summary: SessionSummary?) {
        guard let summary = summary else {
             // If we don't have a summary, we might want to try loading it again or just ignore?
             // But SessionWatcher usually tries to load it.
             // If nil, we can't display much info.
             return
        }
        
        let project = SessionUtils.projectName(from: summary.cwd)
        let session = ActiveSession(
            id: summary.id,
            title: summary.title,
            project: project,
            originator: summary.originator,
            lastModified: summary.endDate,
            url: url
        )
        
        sessionsByURL[url] = session
        updateList()
    }
    
    private func removeSession(url: URL) {
        sessionsByURL.removeValue(forKey: url)
        updateList()
    }
    
    private func updateList() {
        activeSessions = sessionsByURL.values.sorted { $0.lastModified > $1.lastModified }
    }

    private func logSessionEvent(prefix: String, url: URL, summary: SessionSummary?) {
        if let summary {
            let project = SessionUtils.projectName(from: summary.cwd)
            let line = "\(summary.id) \(project) \(summary.title)"
            logger.info("\(prefix) \(line)")
        } else {
            logger.info("\(prefix) \(url.lastPathComponent)")
        }
    }
}
