import Foundation
import SQLite3
import Testing

@testable import Twine

@MainActor
struct MemoryBridgeTests {
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
