import Foundation
import Testing

@testable import Twine

@MainActor
struct FolderTests {
    @Test func branchRefreshRoundTripsAndClearsWhenTheFolderChanges() async throws {
        let data = TemporaryPath()
        let folder = try Self.makeFolder()
        let other = try Self.makeFolder()
        try FileManager.default.createDirectory(
            at: folder.url.appending(path: ".git/objects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: folder.url.appending(path: ".git/refs/heads"), withIntermediateDirectories: true)
        let head = folder.url.appending(path: ".git/HEAD")
        try "ref: refs/heads/main\n".write(to: head, atomically: true, encoding: .utf8)
        let client = BridgeClient(transport: BridgeWorker(dataDirectory: data.url))
        client.start()
        do {
            try await client.waitUntilRunning()
            await client.perform(.openFolder(path: folder.path))
            try await waitUntil { client.snapshot?.folders.openFolder == folder.path }
            try await client.refreshGitBranch(folder: folder.path)
            try await waitUntil { client.snapshot?.folders.currentBranch == "main" }
            try "ref: refs/heads/feature\n".write(to: head, atomically: true, encoding: .utf8)
            try await client.refreshGitBranch(folder: folder.path)
            try await waitUntil { client.snapshot?.folders.currentBranch == "feature" }
            await client.perform(.openFolder(path: other.path))
            try await waitUntil { client.snapshot?.folders.openFolder == other.path }
            #expect(client.snapshot?.folders.currentBranch == nil)
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    private static let noFolders = BridgeFolderState(openFolder: nil, recentFolders: [], unavailableFolder: nil)

    @Test func windowShowsNothingUntilTheFirstSnapshot() {
        // Showing the start page here would flash it before the last folder reopens.
        #expect(WindowContent(connectionState: .idle, snapshot: nil) == .loading)
        #expect(WindowContent(connectionState: .starting, snapshot: nil) == .loading)
    }

    @Test func windowShowsTheOpenFolderOrTheStartPage() {
        var snapshot = BridgeSnapshot.testReady()
        #expect(WindowContent(connectionState: .running, snapshot: snapshot) == .startPage(Self.noFolders))

        snapshot.folders.openFolder = "/Users/me/project"
        #expect(WindowContent(connectionState: .running, snapshot: snapshot) == .folder(path: "/Users/me/project"))
        #expect(WindowContent(connectionState: .failed("No database"), snapshot: snapshot) == .failed("No database"))
    }

    @Test func folderStateDecodesEveryUnavailableReason() throws {
        let json = """
            {"sequence":2,"state":{"status":"ready"},
             "config":{"appearance":{"color_scheme":"system"}},
             "folders":{"openFolder":null,
                        "recentFolders":[{"path":"/p/locked","isMissing":false},{"path":"/p/gone","isMissing":true}],
                        "unavailableFolder":{"path":"/p/locked","reason":"inaccessible"}},
             "terminals":[],"workflows":{"session":null,"workflows":[]}}
            """
        let folders = try JSONDecoder().decode(BridgeSnapshot.self, from: Data(json.utf8)).folders
        #expect(
            folders
                == BridgeFolderState(
                    openFolder: nil,
                    recentFolders: [
                        BridgeRecentFolder(path: "/p/locked", isMissing: false),
                        BridgeRecentFolder(path: "/p/gone", isMissing: true),
                    ],
                    unavailableFolder: BridgeUnavailableFolder(path: "/p/locked", reason: .inaccessible)
                )
        )
        let missing = try JSONDecoder().decode(
            BridgeUnavailableFolder.self,
            from: Data(#"{"path":"/p/gone","reason":"missing"}"#.utf8)
        )
        #expect(missing.reason == .missing)
    }

    @Test func relaunchingReopensTheLastFolder() async throws {
        let dataDirectory = TemporaryPath()
        let folder = try Self.makeFolder()
        let opened = BridgeFolderState(
            openFolder: folder.path,
            recentFolders: [BridgeRecentFolder(path: folder.path, isMissing: false)],
            unavailableFolder: nil
        )

        let worker = BridgeWorker(dataDirectory: dataDirectory.url)
        let snapshot = try await worker.open()
        #expect(snapshot.folders == Self.noFolders)
        #expect(try await worker.send(.openFolder(path: folder.path)).status == .accepted)
        let events = try await worker.events(after: snapshot.sequence, limit: 16)
        #expect(events.map(\.event) == [.foldersChanged(opened)])
        await worker.close()

        let relaunched = BridgeWorker(dataDirectory: dataDirectory.url)
        #expect(try await relaunched.open().folders == opened)
        await relaunched.close()
    }

    @Test func aDeletedLastFolderFallsBackToTheStartPageAndCanBeRemoved() async throws {
        let dataDirectory = TemporaryPath()
        let folder = try Self.makeFolder()
        let worker = BridgeWorker(dataDirectory: dataDirectory.url)
        _ = try await worker.open()
        #expect(try await worker.send(.openFolder(path: folder.path)).status == .accepted)
        await worker.close()
        try FileManager.default.removeItem(at: folder.url)

        let relaunched = BridgeWorker(dataDirectory: dataDirectory.url)
        let snapshot = try await relaunched.open()
        #expect(
            snapshot.folders
                == BridgeFolderState(
                    openFolder: nil,
                    recentFolders: [BridgeRecentFolder(path: folder.path, isMissing: true)],
                    unavailableFolder: BridgeUnavailableFolder(path: folder.path, reason: .missing)
                )
        )

        let reopening = try await relaunched.send(.openFolder(path: folder.path))
        #expect(reopening.error?.code == "folderNotFound")
        #expect(try await relaunched.send(.removeRecentFolder(path: folder.path)).status == .accepted)
        #expect(try await relaunched.snapshot().folders == Self.noFolders)
        await relaunched.close()
    }

    @Test func clientFollowsFolderEvents() async throws {
        let dataDirectory = TemporaryPath()
        let folder = try Self.makeFolder()
        let client = BridgeClient(transport: BridgeWorker(dataDirectory: dataDirectory.url))
        client.start()

        try await waitUntil { client.snapshot?.folders == Self.noFolders }
        await client.perform(.openFolder(path: folder.path))
        try await waitUntil { client.snapshot?.folders.openFolder == folder.path }
        await client.perform(.closeFolder)
        try await waitUntil { client.snapshot?.folders.openFolder == nil }
        #expect(client.snapshot?.folders.recentFolders == [BridgeRecentFolder(path: folder.path, isMissing: false)])
        await client.stop()
    }

    /// Creates a folder to open. The core stores paths without a trailing slash, as `path` has them.
    private static func makeFolder() throws -> TemporaryPath {
        let folder = TemporaryPath()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        return folder
    }
}
