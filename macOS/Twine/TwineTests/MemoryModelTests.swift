import Foundation
import Testing

@testable import Twine

@MainActor
struct MemoryModelTests {
    @Test func openingMemoriesKeepsExistingTabsAndDatabaseRecordsReadOnly() throws {
        let tabs = FileTabsModel()
        let existing = tabs.open(path: "/folder/note.txt", folder: "/folder")
        let source = memorySource(id: "topic.md")
        let file = FilePreview(
            path: source.location, status: .text, text: "---\nname: hidden\n---\n# Topic",
            message: nil, version: .init(fingerprint: "first", utf8BOM: false))
        let request = CoreMemoryRequest(folder: "/folder", sourceID: source.id)
        tabs.openMemory(.init(source: source, text: file.text, message: nil, file: file), request: request)
        let memory = try #require(tabs.selected)
        #expect(tabs.editors.count == 2)
        #expect(tabs.editors.first === existing)
        #expect(memory.isEditable)
        #expect(memory.text == file.text)
        memory.text += "\nEdited"
        tabs.openMemory(.init(source: source, text: file.text, message: nil, file: file), request: request)
        #expect(tabs.editors.count == 2)
        #expect(tabs.selected === memory)
        #expect(memory.text.hasSuffix("Edited"))
        #expect(memory.canSave)
        let record = memorySource(id: "store.sqlite#stage1_outputs/thread/raw_memory")
        tabs.openMemory(
            .init(source: record, text: "# Read-only record", message: nil),
            request: .init(folder: "/folder", sourceID: record.id))
        let reader = try #require(tabs.selected)
        #expect(tabs.editors.count == 3)
        #expect(reader.previewFormat == .markdown)
        #expect(!reader.isEditable)
        reader.text = "This must never be saved"
        #expect(!reader.canSave)
        #expect(!reader.isDirty)
        reader.requestSave()
        #expect(!reader.isSaving)
        tabs.select(existing.id)
        #expect(tabs.selected === existing)
    }

    @Test(arguments: ["refresh", "open", "link"])
    func memoryReadsCannotReplaceACompletedSave(action: String) async throws {
        let transport = DeferredMemoryTransport()
        let client = CoreClient(transport: transport)
        let tabs = FileTabsModel()
        let source = memorySource(id: "saved.md")
        let request = CoreMemoryRequest(folder: "/folder", sourceID: source.id)
        let old = FilePreview(
            path: source.location, status: .text, text: "Before save", message: nil,
            version: .init(fingerprint: "old", utf8BOM: false))
        let read = CoreMemoryRead(source: source, text: old.text, message: nil, file: old)
        tabs.openMemory(read, request: request)
        let editor = try #require(tabs.selected)
        let pending = Task {
            switch action {
            case "refresh": try await tabs.refreshMemory(editor, client: client)
            case "link":
                try await tabs.openMemoryLink(URL(filePath: source.location), request: request, client: client)
            default: try await tabs.openMemory(request: request, client: client)
            }
        }
        if action == "link" {
            try await transport.waitForCatalogs(1)
            await transport.completeCatalog(0, result: .success(.init(sources: [source], diagnostics: [])))
        }
        try await transport.waitForReads(1)
        editor.text = "Saved changes"
        let saved = FilePreview(
            path: source.location, status: .text, text: editor.text, message: nil,
            version: .init(fingerprint: "saved", utf8BOM: false))
        await transport.setSaveResult(.init(status: .saved, file: saved, message: nil))
        editor.requestSave()
        await editor.savePending(client: client)
        let loadID = editor.loadID
        #expect(!editor.isDirty && !editor.isSaving)
        await transport.completeRead(0, result: .success(read))
        try await pending.value
        #expect(editor.text == saved.text)
        #expect(editor.baseline == saved)
        #expect(editor.diskFile == saved)
        #expect(editor.loadID == loadID)
        #expect(tabs.selected === editor)
        #expect(tabs.editors.count == 1)
    }

    @Test func pendingMemoryReadsCannotStealSelectionAndNewestClickWins() async throws {
        for switchToWorkflows in [true, false] {
            let transport = DeferredMemoryTransport()
            let client = CoreClient(transport: transport)
            let tabs = FileTabsModel()
            let first = memorySource(id: "first.md")
            let second = memorySource(id: "second.md")
            let old = Task {
                try await tabs.openMemory(request: .init(folder: nil, sourceID: first.id), client: client)
            }
            try await transport.waitForReads(1)
            if switchToWorkflows {
                tabs.showWorkflows()
            } else {
                let current = Task {
                    try await tabs.openMemory(request: .init(folder: nil, sourceID: second.id), client: client)
                }
                try await transport.waitForReads(2)
                await transport.completeRead(1, result: .success(.init(source: second, text: "second", message: nil)))
                try await current.value
            }
            await transport.completeRead(0, result: .success(.init(source: first, text: "first", message: nil)))
            try await old.value
            #expect(tabs.editors.count == (switchToWorkflows ? 0 : 1))
            #expect(tabs.selected?.path == (switchToWorkflows ? nil : second.location))
        }
    }

    @Test func staleMemoryLinkFailuresDoNotInterruptTheCurrentView() async throws {
        for failCatalog in [true, false] {
            let transport = DeferredMemoryTransport()
            let tabs = FileTabsModel()
            tabs.open(path: "/memory/origin.md", folder: "/memory")
            let source = memorySource(id: "linked.md")
            let task = Task {
                try await tabs.openMemoryLink(
                    URL(filePath: source.location), request: .init(folder: nil),
                    client: CoreClient(transport: transport))
            }
            try await transport.waitForCatalogs(1)
            if failCatalog {
                tabs.showWorkflows()
                await transport.completeCatalog(0, result: .failure(CoreFailure.invalidArgument))
            } else {
                await transport.completeCatalog(0, result: .success(.init(sources: [source], diagnostics: [])))
                try await transport.waitForReads(1)
                tabs.showWorkflows()
                await transport.completeRead(0, result: .failure(CoreFailure.invalidArgument))
            }
            try await task.value
            #expect(tabs.selectedID == nil)
            #expect(tabs.editors.count == 1)
        }
    }

    @Test func pendingMemoryLinkCannotReopenAClosedSourceOrStealSelection() async throws {
        for closeSource in [true, false] {
            let transport = DeferredMemoryTransport()
            let tabs = FileTabsModel()
            let origin = tabs.open(path: "/memory/origin.md", folder: "/memory")
            let source = memorySource(id: "linked.md")
            let task = Task {
                try await tabs.openMemoryLink(
                    URL(filePath: source.location), request: .init(folder: nil),
                    client: CoreClient(transport: transport))
            }
            try await transport.waitForCatalogs(1)
            await transport.completeCatalog(0, result: .success(.init(sources: [source], diagnostics: [])))
            try await transport.waitForReads(1)
            if closeSource {
                #expect(tabs.close(origin.id))
            } else {
                tabs.showWorkflows()
                tabs.select(origin.id)
            }
            let file = FilePreview(path: source.location, status: .text, text: "linked", message: nil, version: nil)
            await transport.completeRead(
                0, result: .success(.init(source: source, text: "linked", message: nil, file: file)))
            try await task.value
            #expect(tabs.editors.count == (closeSource ? 0 : 1))
            #expect(tabs.selectedID == (closeSource ? nil : origin.id))
        }
    }

    @Test func canceledCatalogFailuresCannotReplaceNewResults() async throws {
        let transport = DeferredMemoryTransport()
        let client = CoreClient(transport: transport)
        let model = MemoryModel()
        model.scope = .global
        let old = Task { await model.load(client: client, folder: nil) }
        try await transport.waitForCatalogs(1)
        old.cancel()
        let current = Task { await model.load(client: client, folder: nil) }
        try await transport.waitForCatalogs(2)
        let source = memorySource()
        await transport.completeCatalog(1, result: .success(.init(sources: [source], diagnostics: [])))
        await current.value
        await transport.completeCatalog(0, result: .failure(CoreFailure.invalidArgument))
        await old.value
        #expect(model.state == .available)
        #expect(model.selectedID == source.id)
        #expect(model.scope == source.scope)
    }

    @Test func filtersReconcileSelectionWithinTheCurrentLocation() async throws {
        let transport = DeferredMemoryTransport()
        let model = MemoryModel()
        let task = Task { await model.load(client: CoreClient(transport: transport), folder: nil) }
        try await transport.waitForCatalogs(1)
        let global = memorySource(id: "global", scope: .global, group: "User memories")
        let folder = memorySource(id: "folder", scope: .folder, group: "Folder memories")
        await transport.completeCatalog(0, result: .success(.init(sources: [global, folder], diagnostics: [])))
        await task.value
        model.scope = .folder
        model.reconcileSelection()
        #expect(model.filteredSources.map(\.id) == [folder.id])
        #expect(model.selectedID == folder.id)
        #expect(model.scope == .folder)
        model.query = "does-not-exist"
        model.reconcileSelection()
        #expect(model.selectedID == nil)
    }

    private func memorySource(
        id: String = "source", scope: MemoryScope = .global, group: String = "Memories"
    ) -> CoreMemorySource {
        .init(
            id: id, title: "MEMORY.md", harness: .codex, scope: scope, kind: .durable,
            location: "/memory/\(id)", group: group, format: "md", modifiedAt: nil, example: false, association: nil)
    }
}
