import Foundation
import Testing

@testable import Twine

@MainActor
struct FileAutosaveTests {
    @Test func debounceRejectsOlderEditsAndCancellation() async throws {
        let editor = makeEditor()
        editor.text = "first edit"
        let debounce = Task { await editor.autosave(after: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(10))
        editor.text = "latest edit"
        await debounce.value
        #expect(!editor.isSaving)
        let cancelled = Task { await editor.autosave() }
        cancelled.cancel()
        await cancelled.value
        #expect(!editor.isSaving)
        await editor.autosave(after: .zero)
        #expect(editor.isSaving)
    }

    @Test func cleanAndSettingsBuffersDoNotAutosave() async {
        let clean = makeEditor()
        await clean.autosave(after: .zero)
        #expect(!clean.isSaving)
        let settings = makeEditor(isConfigFile: true)
        settings.text = "config edits"
        await settings.autosave(after: .zero)
        #expect(!settings.isSaving)
        #expect(settings.canSave)
        settings.requestSave()
        #expect(settings.isSaving)
    }

    @Test func editsDuringSavingUseTheNewDiskVersionAndPreserveUndoIdentity() async throws {
        let transport = AutosaveTransport(holdsSave: true)
        let client = CoreClient(transport: transport)
        client.start()
        try await client.waitUntilRunning()
        let editor = makeEditor()
        let loadID = editor.loadID
        editor.text = "first edit"
        await editor.autosave(after: .zero)
        let save = Task { await editor.savePending(client: client) }
        try await waitUntil { await transport.requests.count == 1 }
        editor.text = "typed during save"
        await editor.autosave(after: .zero)
        #expect(await transport.requests.count == 1)
        let revision = editor.autosaveID
        await transport.finishSave()
        await save.value
        #expect(editor.text == "typed during save")
        #expect(editor.baseline?.text == "first edit")
        #expect(editor.loadID == loadID)
        #expect(editor.isDirty)
        #expect(editor.autosaveID != revision)
        await editor.autosave(after: .zero)
        await editor.savePending(client: client)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.last?.text == "typed during save")
        #expect(requests.last?.expectedVersion.fingerprint == "saved-1")
        #expect(!editor.isDirty)
        #expect(editor.loadID == loadID)
        await client.stop()
    }

    @Test(arguments: [FileSaveResult.Status.conflict, .failed])
    func autosavePausesAfterProblemsUntilAnExplicitSuccessfulSave(status: FileSaveResult.Status) async throws {
        let transport = AutosaveTransport(status: status)
        let client = CoreClient(transport: transport)
        client.start()
        try await client.waitUntilRunning()
        let editor = makeEditor()
        editor.text = "my edits"
        await editor.autosave(after: .zero)
        await editor.savePending(client: client)
        #expect(editor.autosavePaused)
        #expect(editor.isDirty)
        #expect(editor.baseline?.text == "original")
        #expect((editor.conflict != nil) == (status == .conflict))
        #expect((editor.failure != nil) == (status == .failed))
        // Dismissing the alert and continuing to type must not retry or overwrite the disk.
        editor.conflict = nil
        editor.failure = nil
        editor.text = "more edits"
        await editor.autosave(after: .zero)
        #expect(!editor.isSaving)
        #expect(await transport.requests.count == 1)
        await transport.succeed()
        editor.requestSave()
        await editor.savePending(client: client)
        #expect(!editor.autosavePaused)
        #expect(!editor.isDirty)
        editor.text = "next edit"
        #expect(editor.canAutosave)
        await client.stop()
    }

    @Test func reloadingAConflictResumesAutosave() async throws {
        let client = CoreClient(transport: AutosaveTransport(status: .conflict))
        client.start()
        try await client.waitUntilRunning()
        let editor = makeEditor()
        editor.text = "my edits"
        await editor.autosave(after: .zero)
        await editor.savePending(client: client)
        editor.reloadConflict(try #require(editor.conflict))
        #expect(!editor.autosavePaused)
        #expect(!editor.isDirty)
        editor.text = "new edit"
        #expect(editor.canAutosave)
        await client.stop()
    }

    private func makeEditor(isConfigFile: Bool = false) -> FileEditorModel {
        let editor = FileEditorModel(path: "/folder/file", folder: "/folder", isConfigFile: isConfigFile)
        editor.receive(
            FilePreview(
                path: editor.path, status: .text, text: "original", message: nil,
                version: FileVersion(fingerprint: "original", utf8BOM: false)))
        return editor
    }
}

private actor AutosaveTransport: CoreTransport {
    private(set) var requests: [FileSaveRequest] = []
    private var status: FileSaveResult.Status
    private var holdsSave: Bool
    private var completion: CheckedContinuation<Void, Never>?

    init(status: FileSaveResult.Status = .saved, holdsSave: Bool = false) {
        self.status = status
        self.holdsSave = holdsSave
    }

    func saveFile(_ request: FileSaveRequest) async -> FileSaveResult {
        requests.append(request)
        if holdsSave { await withCheckedContinuation { completion = $0 } }
        let file = FilePreview(
            path: request.path, status: .text, text: status == .saved ? request.text : "external",
            message: nil, version: FileVersion(fingerprint: "saved-\(requests.count)", utf8BOM: false))
        return FileSaveResult(status: status, file: file, message: status == .failed ? "Save failed" : nil)
    }

    func finishSave() {
        holdsSave = false
        completion?.resume()
        completion = nil
    }

    func succeed() { status = .saved }
    func open() -> CoreSnapshot { .testReady() }
    func close() { finishSave() }
    func snapshot() -> CoreSnapshot { .testReady() }
    func pollFiles(_ request: FileBrowserRequest) -> FileBrowserSnapshot? { nil }
    func send(_ command: CoreCommand) throws -> CoreCommandReceipt { throw CoreFailure.unexpectedCommandResult }
    func events(after sequence: UInt64, limit: UInt32) -> [CoreEvent] { [] }
    func nextTerminalChunk() -> CoreTerminalChunk? { nil }
    func writeTerminalInput(terminalID: UInt64, bytes: Data) {}
    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) {}
}
