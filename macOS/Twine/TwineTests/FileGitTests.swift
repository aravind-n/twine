import Foundation
import Testing

@testable import Twine

@MainActor
struct FileGitTests {
    @Test(arguments: [true, false])
    func unavailableRepositoryDoesNotClaimCleanOrMissingUpstream(loading: Bool) throws {
        let json = """
            {"root":"/repo","changes":[],"error":"Status pending or unavailable","loading":\(loading)}
            """
        let repository = try JSONDecoder().decode(FileGitRepository.self, from: Data(json.utf8))
        #expect(repository.summary != "Clean")
        #expect(repository.branchLabel != "Detached HEAD")
        #expect(repository.history != "No upstream configured")
    }

    @Test func coreBridgePublishesGitStatusWithoutChangingFileContent() async throws {
        let data = TemporaryPath()
        let folder = TemporaryPath()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let file = folder.url.appending(path: "hello 🌲.txt")
        try "initial".write(to: file, atomically: true, encoding: .utf8)
        try git(folder.url, ["init", "-b", "main"])
        try git(folder.url, ["add", "."])
        try git(folder.url, ["commit", "-m", "initial"])
        try "staged".write(to: file, atomically: true, encoding: .utf8)
        try git(folder.url, ["add", "."])
        try "unstaged".write(to: file, atomically: true, encoding: .utf8)
        let worker = CoreWorker(dataDirectory: data.url)
        _ = try await worker.open()
        _ = try await worker.send(.openFolder(path: folder.url.path))
        let request = FileBrowserRequest(folder: folder.url.path, directories: [], file: file.path)
        var observed: FileBrowserSnapshot?
        for _ in 0..<400 {
            let snapshot = try await worker.pollFiles(request)
            if let snapshot, snapshot.git?.repositories.first?.changes.count == 1 {
                observed = snapshot
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        await worker.close()
        let snapshot = try #require(observed)
        let repository = try #require(snapshot.git?.repositories.first)
        #expect(repository.root == folder.url.path)
        #expect(repository.branch == "main")
        #expect(repository.summary == "1 changed")
        #expect(repository.history == "No upstream configured")
        let entry = try #require(snapshot.directories.first?.entries.first { $0.path == file.path })
        #expect(entry.git?.change?.staged == .modified)
        #expect(entry.git?.change?.unstaged == .modified)
        #expect(entry.git?.change?.summary == "Staged: Modified; Unstaged: Modified")
        #expect(snapshot.file?.text == "unstaged")
        #expect(try String(contentsOf: file, encoding: .utf8) == "unstaged")
    }

    private func git(_ folder: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments =
            ["-c", "user.name=Twine Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false"]
            + arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
