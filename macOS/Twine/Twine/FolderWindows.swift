import AppKit
import OSLog
import Observation

private let windowLogger = Logger(subsystem: "com.twineproject.Twine", category: "windows")

@MainActor
@Observable
final class FolderWindowSession: Identifiable {
    let id: UUID
    let worker: CoreWorker
    let coreClient: CoreClient
    let tabs = FileTabsModel()
    var requestedFolder: String?
    let restoresFolder: Bool
    var hasStarted = false
    var isClosing = false
    weak var window: NSWindow?

    init(id: UUID, dataDirectory: URL, folder: String? = nil, restore: Bool = false) {
        self.id = id
        worker = CoreWorker(dataDirectory: dataDirectory, windowMode: true)
        coreClient = CoreClient(transport: worker)
        requestedFolder = folder
        restoresFolder = restore
    }

    var folder: String? {
        coreClient.snapshot?.folders.openFolder ?? requestedFolder
            ?? coreClient.snapshot?.folders.unavailableFolder?.path
    }
}

/// Owns window lifetimes and routing. Folder history and the restore list remain in core.
@MainActor
@Observable
final class FolderWindows {
    private(set) var sessions: [UUID: FolderWindowSession] = [:]
    var isTerminating = false
    private let dataDirectory: URL
    private var hasRestored = false
    private var closingTasks: [UUID: Task<Void, Never>] = [:]

    init(dataDirectory: URL) { self.dataDirectory = dataDirectory }

    func session(id: UUID, folder: String? = nil, restore: Bool = false) -> FolderWindowSession {
        if let existing = sessions[id] { return existing }
        let session = FolderWindowSession(id: id, dataDirectory: dataDirectory, folder: folder, restore: restore)
        sessions[id] = session
        windowLogger.debug("Registered window \(id, privacy: .public); count \(self.sessions.count)")
        return session
    }

    static func canonicalPath(_ path: String) -> String {
        URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    func open(_ path: String, from source: FolderWindowSession, showWindow: (UUID) -> Void) {
        guard !isTerminating, !source.isClosing else { return }
        let path = Self.canonicalPath(path)
        windowLogger.debug("Routing folder open from \(source.id, privacy: .public); count \(self.sessions.count)")
        if let existing = sessions.values.first(where: { !$0.isClosing && $0.folder.map(Self.canonicalPath) == path }) {
            if existing.coreClient.snapshot?.folders.openFolder == nil, existing.requestedFolder == nil {
                existing.requestedFolder = path
                Task { await openFolder(path, in: existing) }
            }
            Task {
                existing.window?.makeKeyAndOrderFront(nil)
                windowLogger.debug(
                    "Focused existing window \(existing.id, privacy: .public); attached \(existing.window != nil)")
            }
            return
        }
        if source.coreClient.snapshot?.folders.openFolder == nil, source.requestedFolder == nil {
            source.requestedFolder = path
            Task { await openFolder(path, in: source) }
        } else {
            let next = session(id: UUID(), folder: path)
            showWindow(next.id)
        }
    }

    func start(_ session: FolderWindowSession, showWindow: (UUID) -> Void) async {
        guard !session.hasStarted, !session.isClosing, !isTerminating else { return }
        session.hasStarted = true
        session.coreClient.start()
        do {
            try await session.coreClient.waitUntilRunning()
            guard !session.isClosing, !isTerminating else { return }
            if let path = session.requestedFolder {
                await openFolder(path, in: session, restore: session.restoresFolder)
            }
            if !hasRestored {
                hasRestored = true
                var finished = false
                defer { if !finished { hasRestored = false } }
                let paths = try await session.worker.restorableFolders()
                let current =
                    session.coreClient.snapshot?.folders.openFolder
                    ?? session.coreClient.snapshot?.folders.unavailableFolder?.path
                for path in paths where Self.canonicalPath(path) != current.map(Self.canonicalPath) {
                    guard !isTerminating, !session.isClosing else { return }
                    let canonical = Self.canonicalPath(path)
                    guard !sessions.values.contains(where: { $0.folder.map(Self.canonicalPath) == canonical }) else {
                        continue
                    }
                    showWindow(self.session(id: UUID(), folder: path, restore: true).id)
                }
                finished = true
            }
        } catch {
            windowLogger.error("Window startup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func openFolder(_ path: String, in session: FolderWindowSession, restore: Bool = false) async {
        defer { session.requestedFolder = nil }
        // A departing runtime must finish removing its old restore entry and ending workflows
        // before another runtime opens that folder. Unrelated live windows keep running.
        await finishClosingWindows()
        guard !session.isClosing, !isTerminating else { return }
        do {
            let receipt = try await session.coreClient.send(
                restore ? .restoreFolder(path: path) : .openFolder(path: path))
            guard receipt.status == .accepted else {
                windowLogger.notice("Folder command rejected: \(receipt.error?.code ?? "unknown", privacy: .public)")
                return
            }
            while session.coreClient.snapshot?.folders.openFolder != path {
                if session.coreClient.snapshot?.folders.unavailableFolder?.path == path { break }
                guard session.coreClient.runState == .running, !session.isClosing, !isTerminating else { return }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            windowLogger.error("Folder open failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func retire(_ session: FolderWindowSession) {
        guard !isTerminating, !session.isClosing else { return }
        session.isClosing = true
        session.tabs.discardAll()
        closingTasks[session.id] = Task {
            await session.coreClient.stopForWindowClose()
            sessions.removeValue(forKey: session.id)
            closingTasks.removeValue(forKey: session.id)
        }
    }

    func finishClosingWindows() async {
        for task in closingTasks.values { await task.value }
    }
}
