import AppKit
import Testing

@testable import Twine

@MainActor
struct FolderWindowsTests {
    @Test func selectingAFolderBeforeTheNewWindowStartsQueuesItForStartup() async throws {
        let data = TemporaryPath()
        let path = try folder()
        let windows = FolderWindows(dataDirectory: data.url)
        var created: UUID?
        windows.chooseFolder(from: nil) { created = $0 }
        let createdID = try #require(created)
        let session = try #require(windows.sessions[createdID])
        windows.open(path.path, from: session) { _ in Issue.record("The picker must reuse its window") }
        #expect(session.requestedFolder == path.path)
        #expect(session.coreClient.runState == .idle)
        await windows.start(session) { _ in Issue.record("Only the selected folder should open") }
        #expect(session.coreClient.snapshot?.folders.openFolder == path.path)
        #expect(session.requestedFolder == nil)
        await session.coreClient.stopForQuit()
    }

    @Test func choosingFolderWithoutAWindowCreatesAPickerAndReusesALiveWindow() throws {
        let data = TemporaryPath()
        let windows = FolderWindows(dataDirectory: data.url)
        var shown: [UUID] = []
        windows.chooseFolder(from: nil) { shown.append($0) }
        let firstID = try #require(shown.first)
        let session = try #require(windows.sessions[firstID])
        #expect(session.isChoosingFolder)
        #expect(!session.hasStarted)
        session.isChoosingFolder = false
        windows.chooseFolder(from: session) { shown.append($0) }
        #expect(session.isChoosingFolder)
        #expect(shown == [session.id])
        session.isClosing = true
        windows.chooseFolder(from: session) { shown.append($0) }
        #expect(shown.count == 2)
        let lastID = try #require(shown.last)
        #expect(windows.sessions[lastID]?.isChoosingFolder == true)
        windows.isTerminating = true
        windows.chooseFolder(from: nil) { _ in Issue.record("Quit must not open a window") }
    }

    @Test func canonicalFoldersIgnoreTrailingSeparatorsAndDots() throws {
        let path = try folder()
        #expect(FolderWindows.canonicalPath(path.path + "/") == FolderWindows.canonicalPath(path.path))
        #expect(FolderWindows.canonicalPath(path.path + "/./") == FolderWindows.canonicalPath(path.path))
    }

    @Test func openingAnotherFolderKeepsTheFirstRuntimeAndDeduplicatesAliases() async throws {
        let data = TemporaryPath()
        let first = try folder()
        let second = try folder()
        let windows = FolderWindows(dataDirectory: data.url)
        let initial = windows.session(id: UUID())
        await windows.start(initial) { _ in Issue.record("A new store should not restore a window") }
        windows.open(first.path, from: initial) { _ in Issue.record("An empty window should be reused") }
        var created: [UUID] = []
        windows.open(second.path, from: initial) { created.append($0) }
        try await waitUntil { initial.coreClient.snapshot?.folders.openFolder == first.path }
        let nextID = try #require(created.first)
        let next = windows.session(id: nextID)
        await windows.start(next) { _ in Issue.record("Only the initial window restores folders") }
        #expect(initial.coreClient !== next.coreClient)
        #expect(initial.tabs !== next.tabs)
        #expect(initial.coreClient.snapshot?.folders.openFolder == first.path)
        #expect(next.coreClient.snapshot?.folders.openFolder == second.path)

        let alias = data.url.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first.url)
        windows.open(alias.path, from: next) { created.append($0) }
        #expect(created.count == 1)
        #expect(windows.sessions.count == 2)
        windows.isTerminating = true
        for session in windows.sessions.values { await session.coreClient.stopForQuit() }
    }

    @Test func closingOneWindowAndQuittingRestoreOnlyRemainingFolders() async throws {
        let data = TemporaryPath()
        let first = try folder()
        let second = try folder()
        let windows = FolderWindows(dataDirectory: data.url)
        let initial = windows.session(id: UUID())
        await windows.start(initial) { _ in }
        windows.open(first.path, from: initial) { _ in }
        try await waitUntil { initial.coreClient.snapshot?.folders.openFolder == first.path }
        var nextID: UUID?
        windows.open(second.path, from: initial) { nextID = $0 }
        let next = windows.session(id: try #require(nextID))
        await windows.start(next) { _ in }
        windows.retire(initial)
        await windows.finishClosingWindows()
        #expect(initial.coreClient.runState == .idle)
        #expect(next.coreClient.runState == .running)
        #expect(try await next.worker.restorableFolders() == [second.path])
        let layouts = WorkflowLayouts(fileURL: data.url.appending(path: "layouts.json"))
        let delegate = AppTerminationDelegate()
        delegate.attach(windows: windows, layouts: layouts)
        var didQuit = false
        #expect(delegate.beginTermination { didQuit = $0 } == .terminateLater)
        try await waitUntil { didQuit }
        #expect(next.coreClient.runState == .idle)
        let restored = FolderWindows(dataDirectory: data.url)
        let restoredSession = restored.session(id: UUID())
        await restored.start(restoredSession) { _ in Issue.record("The closed folder must stay closed") }
        #expect(restoredSession.coreClient.snapshot?.folders.openFolder == second.path)
        await restoredSession.coreClient.stopForQuit()
    }

    @Test func startupRestoresEveryOpenFolderOnce() async throws {
        let data = TemporaryPath()
        let folders = try [folder(), folder()]
        var workers: [CoreWorker] = []
        for folder in folders {
            let worker = CoreWorker(dataDirectory: data.url, windowMode: true)
            _ = try await worker.open()
            _ = try await worker.send(.openFolder(path: folder.path))
            workers.append(worker)
        }
        for worker in workers { await worker.close() }
        let windows = FolderWindows(dataDirectory: data.url)
        let closedDuringStartup = windows.session(id: UUID())
        windows.retire(closedDuringStartup)
        await windows.finishClosingWindows()
        await windows.start(closedDuringStartup) { _ in Issue.record("A closing window must not start") }
        let initial = windows.session(id: UUID())
        var created: [UUID] = []
        await windows.start(initial) { created.append($0) }
        #expect(created.count == 1)
        for id in created { await windows.start(windows.session(id: id)) { _ in Issue.record("Restore repeated") } }
        #expect(
            Set(windows.sessions.values.compactMap { $0.coreClient.snapshot?.folders.openFolder })
                == Set(folders.map(\.path)))
        windows.isTerminating = true
        for session in windows.sessions.values { await session.coreClient.stopForQuit() }
    }

    @Test func reopeningAClosingFolderWaitsForItsCleanupAndPreservesRestoration() async throws {
        let data = TemporaryPath()
        let first = try folder()
        let second = try folder()
        let windows = FolderWindows(dataDirectory: data.url)
        let initial = windows.session(id: UUID())
        await windows.start(initial) { _ in }
        windows.open(first.path, from: initial) { _ in }
        try await waitUntil { initial.coreClient.snapshot?.folders.openFolder == first.path }
        var created: [UUID] = []
        windows.open(second.path, from: initial) { created.append($0) }
        let other = windows.session(id: try #require(created.first))
        await windows.start(other) { _ in }
        windows.retire(initial)
        #expect(initial.isClosing)
        windows.open(first.path, from: other) { created.append($0) }
        #expect(created.count == 2)
        let reopened = windows.session(id: try #require(created.last))
        await windows.start(reopened) { _ in }
        #expect(windows.sessions[initial.id] == nil)
        #expect(reopened.coreClient.snapshot?.folders.openFolder == first.path)
        #expect(Set(try await reopened.worker.restorableFolders()) == Set([first.path, second.path]))
        windows.isTerminating = true
        for session in windows.sessions.values { await session.coreClient.stopForQuit() }
    }

    @Test func anUnavailableFolderKeepsItsWindowWhenAnotherFolderCannotOpen() async throws {
        let data = TemporaryPath()
        let first = try folder()
        let missing = TemporaryPath()
        let seed = CoreWorker(dataDirectory: data.url, windowMode: true)
        _ = try await seed.open()
        _ = try await seed.send(.openFolder(path: first.path))
        await seed.close()
        try FileManager.default.removeItem(at: first.url)
        let windows = FolderWindows(dataDirectory: data.url)
        let initial = windows.session(id: UUID())
        await windows.start(initial) { _ in Issue.record("Only one folder should restore") }
        #expect(initial.folder == first.path)
        var created: [UUID] = []
        windows.open(missing.path, from: initial) { created.append($0) }
        #expect(created.count == 1)
        guard let nextID = created.first else {
            await initial.coreClient.stopForQuit()
            return
        }
        let next = windows.session(id: nextID)
        await windows.start(next) { _ in Issue.record("Restoration should not repeat") }
        try await waitUntil { next.coreClient.snapshot?.folders.unavailableFolder?.path == missing.path }
        #expect(initial.folder == first.path)
        #expect(initial.coreClient.snapshot?.folders.unavailableFolder?.path == first.path)
        #expect(next.folder == missing.path)
        try FileManager.default.createDirectory(at: first.url, withIntermediateDirectories: true)
        windows.open(first.path, from: next) { _ in Issue.record("The original window must be reused") }
        try await waitUntil { initial.coreClient.snapshot?.folders.openFolder == first.path }
        #expect(windows.sessions.count == 2)
        windows.retire(next)
        await windows.finishClosingWindows()
        #expect(try await initial.worker.restorableFolders() == [first.path])
        await initial.coreClient.stopForQuit()
    }

    private func folder() throws -> TemporaryPath {
        let path = TemporaryPath()
        try FileManager.default.createDirectory(at: path.url, withIntermediateDirectories: true)
        return path
    }
}
