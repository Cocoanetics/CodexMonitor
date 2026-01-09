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

    struct TodaySession: Identifiable, Equatable {
        let id: String
        let title: String
        let project: String
        let originator: String
        let startDate: Date
        let endDate: Date
        let cwd: String
        let url: URL
    }

    @Published var activeSessions: [ActiveSession] = []
    @Published var todaySessions: [TodaySession] = []
    @Published var selectedSession: ActiveSession?
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
        refreshTodaySessions()
        let watcher = SessionWatcher(watchedFile: nil, activeWindow: 30)
        self.watcher = watcher
        
        watcher.onSessionActive = { [weak self] url, summary in
            Task { @MainActor [weak self] in
                self?.logSessionEvent(prefix: "Session active:", url: url, summary: summary)
                self?.updateSession(url: url, summary: summary)
                self?.refreshTodaySessions()
            }
        }
        
        watcher.onSessionModified = { [weak self] url, summary in
            Task { @MainActor [weak self] in
                self?.logSessionEvent(prefix: "Session modified:", url: url, summary: summary)
                self?.updateSession(url: url, summary: summary)
                self?.refreshTodaySessions()
            }
        }
        
        watcher.onSessionInactive = { [weak self] url, summary in
             Task { @MainActor [weak self] in
                self?.logSessionEvent(prefix: "Session inactive:", url: url, summary: summary)
                self?.removeSession(url: url)
                self?.refreshTodaySessions()
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
        if selectedSession?.url == url {
            selectedSession = session
        }
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

    func selectSession(_ session: ActiveSession) {
        selectedSession = session
    }

    func selectSession(summary: SessionSummary, url: URL) {
        let project = SessionUtils.projectName(from: summary.cwd)
        selectedSession = ActiveSession(
            id: summary.id,
            title: summary.title,
            project: project,
            originator: summary.originator,
            lastModified: summary.endDate,
            url: url
        )
    }

    private func refreshTodaySessions() {
        let path = SessionViewModel.todayPath()
        do {
            let snapshot = try SessionLoader.sessionFilesSnapshot(under: path)
            let sortedFiles = snapshot.sorted { $0.value > $1.value }
                .prefix(10)
                .map { $0.key }
            let summaries = try sortedFiles.compactMap { url -> TodaySession? in
                guard let summary = try SessionLoader.loadSummary(from: url) else { return nil }
                let project = SessionUtils.projectName(from: summary.cwd)
                return TodaySession(
                    id: summary.id,
                    title: summary.title,
                    project: project,
                    originator: summary.originator,
                    startDate: summary.startDate,
                    endDate: summary.endDate,
                    cwd: summary.cwd,
                    url: url
                )
            }
            todaySessions = summaries
        } catch {
            todaySessions = []
        }
    }

    private static func todayPath(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: now)
    }

    func isActive(_ session: TodaySession) -> Bool {
        sessionsByURL[session.url] != nil
    }
}
