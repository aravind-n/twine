import AppKit
import Foundation
import Testing

@testable import Twine

@MainActor
struct SettingsEditorTests {
    @Test func configEventsDecodeAndApplyAutosavePreferences() async throws {
        let json = """
            {"sequence":2,"event":{"type":"configChanged","config":{
             "appearance":{"color_scheme":"system"},"terminal":{"font_family":"","font_size":13},
             "editor":{"autosave":false,"autosave_delay_ms":2000}}}}
            """
        let event = try JSONDecoder().decode(CoreEvent.self, from: Data(json.utf8))
        let client = CoreClient(transport: SettingsFileTransport(reloadEvent: event))
        client.start()
        try await client.waitUntilRunning()
        _ = try await client.send(.reloadConfig)
        try await waitUntil { client.snapshot?.sequence == 2 }
        #expect(client.snapshot?.config.editor.autosave == false)
        #expect(client.snapshot?.config.editor.autosaveDelayMilliseconds == 2000)
        await client.stop()
    }

    @Test func configChangedEventUpdatesTheFontAndPaletteWithoutRestarting() async throws {
        let ansi = Array(repeating: "\"#123456\"", count: 16).joined(separator: ",")
        let palette = """
            {"background":"#000000","foreground":"#ffffff","cursor":"#ffffff",
             "selection":"#333333","ansi":[\(ansi)]}
            """
        let json = """
            {"sequence":2,"event":{"type":"configChanged","config":{
             "appearance":{"color_scheme":"dark"},"terminal":{
             "font_family":"Menlo","font_size":18,"palettes":{"light":\(palette),"dark":\(palette)}}}}}
            """
        let event = try JSONDecoder().decode(CoreEvent.self, from: Data(json.utf8))
        let transport = SettingsFileTransport(reloadEvent: event)
        let client = CoreClient(transport: transport)
        client.start()
        do {
            try await client.waitUntilRunning()
            #expect(client.terminalFont.pointSize == 13)
            let receipt = try await client.send(.reloadConfig)
            #expect(receipt.status == .accepted)
            try await waitUntil { client.snapshot?.sequence == 2 }
            #expect(client.snapshot?.config.appearance.colorScheme == .dark)
            #expect(client.terminalFont.pointSize == 18)
            #expect(client.snapshot?.config.terminal.palettes?.dark.ansi[4] == "#123456")
            #expect(client.runState == .running)
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func saveCallbackRunsAfterSavingAndKeepsTheBaselineOnReloadFailure(fails: Bool) async throws {
        let client = CoreClient(transport: SettingsFileTransport())
        let file = try await client.configFile()
        let editor = FileEditorModel(path: file.path, folder: "/config/twine", isConfigFile: true)
        editor.receive(file)
        editor.text = "terminal.font_size = 18\n"
        editor.requestSave()
        var called = false
        await editor.savePending(client: client) {
            called = true
            #expect(editor.isSaving)
            #expect(editor.baseline?.text == editor.text)
            if fails { throw CoreFailure.invalidArgument }
        }
        #expect(called)
        #expect(!editor.isSaving)
        #expect(!editor.isDirty)
        #expect((editor.failure != nil) == fails)
    }

    @Test func aConflictedSaveDoesNotReloadSettings() async throws {
        let client = CoreClient(transport: SettingsFileTransport(conflicts: true))
        let file = try await client.configFile()
        let editor = FileEditorModel(path: file.path, folder: "/config/twine", isConfigFile: true)
        editor.receive(file)
        editor.text = "terminal.font_size = 18\n"
        editor.requestSave()
        var called = false
        await editor.savePending(client: client) { called = true }
        #expect(!called)
        #expect(editor.isDirty)
        #expect(editor.conflict != nil)
    }

    @Test func configEditorLoadsAndSavesWithoutStartingAFolderRuntime() async throws {
        let transport = SettingsFileTransport()
        let client = CoreClient(transport: transport)
        let file = try await client.configFile()
        let editor = FileEditorModel(path: file.path, folder: "/config/twine", isConfigFile: true)
        editor.receive(file)
        editor.text = "terminal.font_size = 18\n"
        editor.requestSave()
        await editor.savePending(client: client)
        #expect(editor.failure == nil)
        #expect(!editor.isDirty)
        #expect(!editor.isSaving)
        #expect(editor.baseline?.text == "terminal.font_size = 18\n")
        #expect(await transport.saved?.path == "/config/twine/config.toml")
        #expect(client.runState == .idle)
        #expect(client.snapshot == nil)
    }
}

private actor SettingsFileTransport {
    private(set) var saved: FileSaveRequest?
    private let reloadEvent: CoreEvent?
    private let conflicts: Bool
    private var eventsToDeliver: [CoreEvent] = []

    init(reloadEvent: CoreEvent? = nil, conflicts: Bool = false) {
        self.reloadEvent = reloadEvent
        self.conflicts = conflicts
    }

    func configFile() -> FilePreview {
        FilePreview(
            path: "/config/twine/config.toml", status: .text, text: "# Original\n", message: nil,
            version: FileVersion(fingerprint: "one", utf8BOM: false))
    }

    func saveConfigFile(_ request: FileSaveRequest) -> FileSaveResult {
        saved = request
        return FileSaveResult(
            status: conflicts ? .conflict : .saved,
            file: FilePreview(
                path: request.path, status: .text, text: request.text, message: nil,
                version: FileVersion(fingerprint: "two", utf8BOM: false)), message: nil)
    }

    func open() -> CoreSnapshot { .testReady() }
    func close() {}
    func snapshot() -> CoreSnapshot { .testReady() }
    func pollFiles(_ request: FileBrowserRequest) -> FileBrowserSnapshot? { nil }
    func saveFile(_ request: FileSaveRequest) throws -> FileSaveResult { throw CoreFailure.unexpectedCommandResult }
    func send(_ command: CoreCommand) throws -> CoreCommandReceipt {
        guard case .reloadConfig = command, let reloadEvent else { throw CoreFailure.unexpectedCommandResult }
        eventsToDeliver.append(reloadEvent)
        return CoreCommandReceipt(requestID: 1, status: .accepted, error: nil)
    }
    func events(after sequence: UInt64, limit: UInt32) -> [CoreEvent] {
        eventsToDeliver.filter { $0.sequence > sequence }
    }
    func nextTerminalChunk() -> CoreTerminalChunk? { nil }
    func writeTerminalInput(terminalID: UInt64, bytes: Data) {}
    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) {}
}

extension SettingsFileTransport: CoreTransport {}
