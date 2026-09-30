import Foundation
import Testing

@testable import Twine

@MainActor
struct FileEditorTests {
    @Test func dirtyBufferSurvivesDiskUpdatesAndReloadResetsUndoIdentity() {
        let editor = FileEditorModel()
        editor.select("/folder/file", folder: "/folder")
        let original = preview("original", version: "one")
        editor.receive(original)
        let loaded = editor.loadID
        editor.text = "my edits"
        editor.receive(preview("external", version: "two"))
        #expect(editor.text == "my edits")
        #expect(editor.baseline == original)
        #expect(editor.loadID == loaded)
        #expect(editor.isDirty)
        editor.text = "original"  // Undo back to the baseline is clean.
        #expect(!editor.isDirty)
        editor.receive(preview("external", version: "two"))
        #expect(editor.text == "external")
        #expect(editor.loadID != loaded)
        editor.text = "more edits"
        editor.reloadConflict(preview("reloaded", version: "three"))
        #expect(editor.text == "reloaded")
        #expect(!editor.isDirty)
        #expect(editor.baseline?.version?.fingerprint == "three")
    }

    @Test func saveConflictOverwriteAndFailureKeepTheCorrectBaseline() async throws {
        let data = TemporaryPath()
        let folder = TemporaryPath()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let file = folder.url.appending(path: "file.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        let client = CoreClient(transport: CoreWorker(dataDirectory: data.url))
        client.start()
        try await client.waitUntilRunning()
        _ = try await client.send(.openFolder(path: folder.url.path))
        let editor = FileEditorModel()
        editor.select(file.path, folder: folder.url.path)
        let request = FileBrowserRequest(folder: folder.url.path, directories: [], file: file.path)
        for _ in 0..<200 {
            if let snapshot = try await client.pollFiles(request) {
                editor.receive(snapshot.file)
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(editor.text == "original")
        let loadID = editor.loadID
        editor.text = "saved"
        editor.requestSave()
        #expect(editor.isSaving)
        editor.receive(preview("stale", version: "stale", path: file.path))
        await editor.savePending(client: client)
        #expect(!editor.isDirty)
        #expect(editor.loadID == loadID)  // A save retains native undo history.
        #expect(try String(contentsOf: file, encoding: .utf8) == "saved")
        editor.text = "original"  // Undo after saving makes the buffer dirty again.
        #expect(editor.isDirty)
        try "external".write(to: file, atomically: true, encoding: .utf8)
        editor.requestSave()
        await editor.savePending(client: client)
        #expect(editor.conflict?.text == "external")
        #expect(editor.text == "original")
        #expect(editor.isDirty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "external")
        editor.requestSave(overwrite: true)
        await editor.savePending(client: client)
        #expect(editor.conflict == nil)
        #expect(!editor.isDirty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
        try await verifyFailedSave(editor: editor, client: client, file: file)
        await client.stop()
    }

    private func verifyFailedSave(editor: FileEditorModel, client: CoreClient, file: URL) async throws {
        editor.text = String(repeating: "x", count: 2 * 1024 * 1024 + 1)
        editor.requestSave()
        await editor.savePending(client: client)
        #expect(editor.failure != nil)
        #expect(editor.isDirty)
        #expect(!editor.isSaving)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
    }

    private func preview(_ text: String, version: String, path: String = "/folder/file") -> FilePreview {
        FilePreview(
            path: path, status: .text, text: text, message: nil,
            version: FileVersion(fingerprint: version, utf8BOM: false))
    }
}
