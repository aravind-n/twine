import AppKit
import Foundation
import Testing

@testable import Twine

@MainActor
struct FileBrowserTests {
    @Test func lineSelectionUsesUTF16AndHandlesLineEndings() {
        let text = "🌲 first\r\nsecond\n"
        #expect(FileTextView.lineRange(in: text, line: 1) == NSRange(location: 0, length: 8))
        #expect(FileTextView.lineRange(in: text, line: 2) == NSRange(location: 10, length: 6))
        #expect(FileTextView.lineRange(in: text, line: 3) == NSRange(location: 17, length: 0))
        #expect(FileTextView.lineRange(in: text, line: 4) == nil)
        #expect(FileTextView.lineRange(in: "", line: 1) == NSRange(location: 0, length: 0))
        #expect(FileTextView.lineRange(in: "last", line: 2) == nil)
        #expect(FileTextView.lineRange(in: text, line: 0) == nil)
    }

    @Test func collapsingDirectoryStopsPollingItsDescendants() {
        let model = FileBrowserModel()
        model.expanded = ["/folder/a", "/folder/a/b", "/folder/ab"]
        model.toggle("/folder/a")
        #expect(model.expanded == ["/folder/ab"])
        #expect(model.request(folder: "/folder").directories == ["/folder/ab"])
    }

    @Test func collapsingRootClearsDescendantsAndKeepsTheSelectedFileRequest() {
        let model = FileBrowserModel()
        #expect(model.isRootExpanded)
        model.toggle("/folder/a")
        model.toggle("/folder/a/b")
        model.toggleRoot()
        #expect(!model.isRootExpanded)
        #expect(model.expanded.isEmpty)
        let request = model.request(folder: "/folder", file: "/folder/a/b/file.txt")
        #expect(request.directories.isEmpty)
        #expect(request.file == "/folder/a/b/file.txt")
        model.toggleRoot()
        #expect(model.isRootExpanded)
        #expect(model.expanded.isEmpty)
    }

    @Test func collapseAllCollapsesTheRootAndEveryDescendant() {
        let model = FileBrowserModel()
        model.toggle("/folder/a")
        model.toggle("/folder/a/b")
        model.collapseAll()
        #expect(!model.isRootExpanded)
        #expect(model.request(folder: "/folder").directories.isEmpty)
        model.collapseAll()
        #expect(!model.isRootExpanded)
    }

    @Test func rootExpansionLeavesTheFullDirectoryLimitAvailable() {
        let model = FileBrowserModel()
        for index in 0..<256 { model.toggle("/folder/\(index)") }
        #expect(model.expanded.count == 256)
        #expect(model.request(folder: "/folder").directories.count == 256)
        #expect(model.failure == nil)
        model.toggle("/folder/extra")
        #expect(model.expanded.count == 256)
        #expect(model.failure != nil)
    }

    @Test func corePollsDiskChangesAndSuppressesUnchangedSnapshots() async throws {
        let data = TemporaryPath()
        let folder = TemporaryPath()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let file = folder.url.appending(path: "hello.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let worker = CoreWorker(dataDirectory: data.url)
        _ = try await worker.open()
        _ = try await worker.send(.openFolder(path: folder.url.path))
        var request = FileBrowserRequest(folder: folder.url.path, directories: [], file: file.path)
        let initial = try #require(try await pollSnapshot(worker, request: request))
        #expect(initial.file?.text == "hello")
        #expect(initial.directories.count == 1)
        request.revision = initial.revision
        #expect(try await worker.pollFiles(request) == nil)
        try "changed".write(to: file, atomically: true, encoding: .utf8)
        let changed = try #require(try await pollSnapshot(worker, request: request))
        #expect(changed.file?.text == "changed")
        try FileManager.default.removeItem(at: file)
        request.revision = changed.revision
        let deleted = try #require(try await pollSnapshot(worker, request: request))
        #expect(deleted.file?.status == .missing)
        #expect(deleted.directories[0].entries.isEmpty)
        await worker.close()
    }
    private func pollSnapshot(
        _ worker: CoreWorker, request: FileBrowserRequest
    ) async throws -> FileBrowserSnapshot? {
        for _ in 0..<200 {
            if let snapshot = try await worker.pollFiles(request) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

}
