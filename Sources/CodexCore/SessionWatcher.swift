import Foundation
import Darwin

public final class SessionWatcher: @unchecked Sendable {
    public enum UpdateReason {
        case fsevent
        case fileEvent
        case poll
    }

    public typealias UpdateHandler = (URL, SessionSummary?) -> Void

    private struct FileWatcher {
        let source: DispatchSourceFileSystemObject
        let fileDescriptor: Int32
        let identity: FileIdentity?
    }

    private var snapshot: [URL: Date]
    private let watchedFile: URL?
    private let activeWindow: TimeInterval
    private var pendingWorkItem: DispatchWorkItem?
    private var pollTimer: DispatchSourceTimer?
    private var watchers: [URL: FileWatcher] = [:]
    private var cachedSummaries: [URL: SessionSummary] = [:]
    private let queue = DispatchQueue(label: "codex.core.watch")
    
    // Callbacks
    public var onSessionActive: UpdateHandler?
    public var onSessionInactive: UpdateHandler?
    public var onSessionModified: UpdateHandler?
    public var onError: ((Error) -> Void)?

    private var streamRef: FSEventStreamRef?

    public init(watchedFile: URL?, activeWindow: TimeInterval) {
        self.watchedFile = watchedFile
        self.activeWindow = activeWindow
        self.snapshot = [:]
    }
    
    deinit {
        stop()
    }

    public func start() throws {
        let targetURL: URL
        if let watchedFile {
            let root = watchedFile.deletingLastPathComponent()
            targetURL = root
            snapshot = [:] // Initialize empty
        } else {
            targetURL = SessionLoader.sessionsRoot
            snapshot = try SessionLoader.sessionFilesSnapshot(under: nil)
        }
        
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            throw SessionError.invalidWatchTarget(targetURL.path)
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [targetURL.path] as CFArray
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fseventsCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else {
            throw SessionError.invalidWatchTarget(targetURL.path)
        }
        
        self.streamRef = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global())
        
        guard FSEventStreamStart(stream) else {
            throw SessionError.invalidWatchTarget(targetURL.path)
        }
        
        bootstrapWatchers()
        startPolling(interval: 5.0)
    }
    
    public func stop() {
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
        pollTimer?.cancel()
        pollTimer = nil
        
        for watcher in watchers.values {
            watcher.source.cancel()
            close(watcher.fileDescriptor)
        }
        watchers.removeAll()
    }

    fileprivate func scheduleUpdate(reason: UpdateReason) {
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performSnapshotUpdate(reason: reason)
        }
        pendingWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func bootstrapWatchers() {
        queue.async { [weak self] in
            self?.performBootstrap()
        }
    }

    private func performBootstrap() {
        do {
            if let watchedFile {
                _ = installWatcher(for: watchedFile)
                if let modified = try SessionLoader.sessionFileSnapshot(for: watchedFile) {
                    snapshot[watchedFile] = modified
                }
                return
            }

            let latest = try SessionLoader.sessionFilesSnapshot(under: nil)
            let activeCutoff = Date().addingTimeInterval(-activeWindow)
            for (url, modified) in latest where modified >= activeCutoff {
                _ = installWatcher(for: url)
                snapshot[url] = modified
            }
        } catch {
            onError?(error)
        }
    }

    private func startPolling(interval: TimeInterval) {
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
                try notifyUpdatesForWatchedFiles(force: false)
            case .fileEvent:
                try notifyUpdatesForWatchedFiles(force: true)
            case .poll:
                try refreshWatchers()
            }
        } catch {
            onError?(error)
        }
    }

    private func refreshWatchers() throws {
        guard watchedFile == nil else { return }
        let latest = try SessionLoader.sessionFilesSnapshot(under: nil)
        let latestURLs = Set(latest.keys)
        let activeCutoff = Date().addingTimeInterval(-activeWindow)
        
        // Remove old watchers
        for (url, watcher) in watchers where !latestURLs.contains(url) {
            removeWatcher(watcher, url: url, notifyInactive: false)
        }
        
        // Add new watchers or re-add if identity changed
        for (url, modified) in latest where modified >= activeCutoff {
            let currentIdentity = SessionLoader.fileIdentity(for: url)
            if let watcher = watchers[url] {
                if watcher.identity != currentIdentity {
                    removeWatcher(watcher, url: url, notifyInactive: false)
                    _ = installWatcher(for: url)
                }
            } else {
                _ = installWatcher(for: url)
            }
            snapshot[url] = modified
        }
        
        // Remove watchers for stale files
        for (url, watcher) in watchers {
            if let modified = latest[url], modified < activeCutoff {
                removeWatcher(watcher, url: url, notifyInactive: true)
            }
        }
    }

    private func notifyUpdatesForWatchedFiles(force: Bool) throws {
        if let watchedFile {
            if force {
                try notifyUpdateForFileEvent(for: watchedFile)
            } else {
                try notifyUpdateIfNeeded(for: watchedFile)
            }
            return
        }
        for url in watchers.keys.sorted(by: { $0.path < $1.path }) {
            if force {
                try notifyUpdateForFileEvent(for: url)
            } else {
                try notifyUpdateIfNeeded(for: url)
            }
        }
    }

    private func notifyUpdateIfNeeded(for url: URL) throws {
        guard let modified = try SessionLoader.sessionFileSnapshot(for: url) else { return }
        let oldDate = snapshot[url]
        guard oldDate == nil || modified > oldDate! else { return }
        
        if let summary = try cacheSummaryIfNeeded(for: url) {
            onSessionModified?(url, summary)
            snapshot[url] = summary.endDate
        } else {
            onSessionModified?(url, nil)
            snapshot[url] = modified
        }
    }

    private func notifyUpdateForFileEvent(for url: URL) throws {
        let eventTime = Date()
        if let summary = cachedSummaries[url] {
            // Optimistic update of end date
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
            onSessionModified?(url, updated)
            return
        }
        if let summary = try cacheSummaryIfNeeded(for: url) {
            snapshot[url] = summary.endDate
            onSessionModified?(url, summary)
        } else {
            snapshot[url] = eventTime
            onSessionModified?(url, nil)
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

    private func removeWatcher(_ watcher: FileWatcher, url: URL, notifyInactive: Bool) {
        if notifyInactive, let summary = cachedSummaries[url] {
            onSessionInactive?(url, summary)
        }
        watcher.source.cancel()
        watchers.removeValue(forKey: url)
        snapshot.removeValue(forKey: url)
        cachedSummaries.removeValue(forKey: url)
    }

    private func notifyActiveSession(for url: URL) throws {
        if let summary = try cacheSummaryIfNeeded(for: url) {
            onSessionActive?(url, summary)
        } else {
            onSessionActive?(url, nil)
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
    let watcher = Unmanaged<SessionWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
    watcher.scheduleUpdate(reason: .fsevent)
}
