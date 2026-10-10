import Foundation
import SQLite3
import Testing

@testable import Twine

@MainActor
struct MemoryBridgeTests {
    @Test(arguments: [true, false])
    func markdownEditorUsesAutosaveSettingsAndDetectsHarnessChanges(autosave: Bool) async throws {
        let fixture = FileManager.default.temporaryDirectory.appending(path: "TwineMemorySave-\(UUID())")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let memory = fixture.appending(path: "home/.codex/memories/MEMORY.md")
        try FileManager.default.createDirectory(
            at: memory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Original\n".write(to: memory, atomically: true, encoding: .utf8)
        let client = CoreClient(transport: CoreWorker(dataDirectory: fixture.appending(path: "unused")))
        var request = CoreMemoryRequest(folder: nil, examplesRoot: fixture.path)
        let catalog = try await client.memoryCatalog(request)
        request.sourceID = try #require(catalog.sources.first { $0.location == memory.path }).id
        let file = try #require(try await client.memoryRead(request).file)
        let editor = FileEditorModel(
            path: file.path, folder: memory.deletingLastPathComponent().path, memoryRequest: request)
        editor.receive(file)
        editor.configureAutosave(.init(autosave: autosave))
        editor.text = "# Saved\n"
        await editor.autosave(after: .zero)
        #expect(editor.isSaving == autosave)
        #expect(try String(contentsOf: memory, encoding: .utf8) == "# Original\n")
        if !autosave { editor.requestSave() }
        await editor.savePending(client: client)
        #expect(!editor.isDirty)
        #expect(try String(contentsOf: memory, encoding: .utf8) == "# Saved\n")
        try "# Harness update\n".write(to: memory, atomically: true, encoding: .utf8)
        editor.text = "# My draft\n"
        editor.requestSave()
        await editor.savePending(client: client)
        #expect(editor.conflict?.text == "# Harness update\n")
        #expect(editor.autosavePaused)
        #expect(editor.text == "# My draft\n")
        #expect(try String(contentsOf: memory, encoding: .utf8) == "# Harness update\n")
    }

    @Test func realBridgeDiscoversAndReadsFileAndSQLiteExamplesWithoutStartingRuntime() async throws {
        let fixture = FileManager.default.temporaryDirectory.appending(path: "TwineMemoryBridge-\(UUID())")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let codex = fixture.appending(path: "home/.codex")
        let memory = codex.appending(path: "memories/memory_summary.md")
        try FileManager.default.createDirectory(
            at: memory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "v1\nexample file memory".write(to: memory, atomically: true, encoding: .utf8)
        let database = codex.appending(path: "memories_1.sqlite")
        try createMemoryDatabase(database)
        let before = try Data(contentsOf: database)
        let runtime = fixture.appending(path: "unused-runtime")
        let client = CoreClient(transport: CoreWorker(dataDirectory: runtime))
        let catalog = try await client.memoryCatalog(.init(folder: nil, examplesRoot: fixture.path))
        let record = try #require(catalog.sources.first { $0.example && $0.kind == .rawMemory })
        let read = try await client.memoryRead(.init(folder: nil, sourceID: record.id, examplesRoot: fixture.path))
        #expect(read.text == "example SQLite memory")
        #expect(read.source.location.contains("#stage1_outputs/fixture/raw_memory"))
        #expect(read.file == nil)
        let rejected = try await client.memorySave(
            .init(
                source: .init(folder: nil, sourceID: record.id, examplesRoot: fixture.path),
                text: "should not save", expectedVersion: .init(fingerprint: "unused", utf8BOM: false), overwrite: true)
        )
        #expect(rejected.status == .failed)
        let file = try #require(catalog.sources.first { $0.example && $0.location == memory.path })
        let fileRead = try await client.memoryRead(.init(folder: nil, sourceID: file.id, examplesRoot: fixture.path))
        #expect(fileRead.text == "v1\nexample file memory")
        #expect(try Data(contentsOf: database) == before)
        #expect(!FileManager.default.fileExists(atPath: runtime.path))
    }

    private func createMemoryDatabase(_ path: URL) throws {
        var database: OpaquePointer?
        #expect(sqlite3_open(path.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let result = sqlite3_exec(
            database,
            """
            CREATE TABLE stage1_outputs(thread_id TEXT, raw_memory TEXT, rollout_summary TEXT, generated_at INTEGER);
            INSERT INTO stage1_outputs VALUES('fixture','example SQLite memory','example summary',100);
            """, nil, nil, nil)
        #expect(result == SQLITE_OK)
    }
}
