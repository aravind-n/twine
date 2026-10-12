import Foundation
import Observation

/// Open file tabs are presentation state. Each editor keeps its own buffer and disk version.
@Observable
final class FileTabsModel {
    private(set) var editors: [FileEditorModel] = []
    private(set) var selectedID: UUID? {
        didSet { memoryLinkID = UUID() }
    }
    private var memoryLinkID = UUID()

    var selected: FileEditorModel? { editors.first { $0.id == selectedID } }
    var isDirty: Bool { editors.contains { $0.isDirty } }
    var isSaving: Bool { editors.contains { $0.isSaving } }

    @discardableResult
    func open(path: String, folder: String, navigationURL: URL? = nil) -> FileEditorModel {
        let editor: FileEditorModel
        if let existing = editors.first(where: { $0.path == path }) {
            editor = existing
        } else {
            editor = FileEditorModel(path: path, folder: folder)
            editors.append(editor)
        }
        if let navigationURL { editor.navigate(to: navigationURL) }
        selectedID = editor.id
        return editor
    }

    func select(_ id: UUID) {
        guard editors.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func openMemory(
        _ file: FilePreview, request: CoreMemoryRequest, source: CoreMemorySource? = nil
    ) {
        let editor: FileEditorModel
        if let existing = editors.first(where: { $0.path == file.path }) {
            editor = existing
        } else {
            editor = FileEditorModel(
                path: file.path, folder: URL(filePath: file.path).deletingLastPathComponent().path,
                memoryRequest: request)
            editors.append(editor)
        }
        editor.useMemorySource(request, source: source)
        editor.receive(file)
        selectedID = editor.id
    }

    func openMemory(_ read: CoreMemoryRead, request: CoreMemoryRequest) {
        openMemory(read.preview, request: request, source: read.source)
    }

    func openMemory(request: CoreMemoryRequest, client: CoreClient) async throws {
        let origin = selectedID
        let linkID = UUID()
        memoryLinkID = linkID
        let generations = Dictionary(uniqueKeysWithValues: editors.map { ($0.id, $0.generation) })
        do {
            let read = try await client.memoryRead(request)
            guard isCurrentMemoryLink(linkID, origin: origin) else { return }
            openMemory(read, request: request, generations: generations)
        } catch {
            guard isCurrentMemoryLink(linkID, origin: origin) else { return }
            throw error
        }
    }

    func openMemoryLink(_ url: URL, request: CoreMemoryRequest, client: CoreClient) async throws {
        guard let origin = selectedID else { return }
        let linkID = UUID()
        memoryLinkID = linkID
        do {
            let catalog = try await client.memoryCatalog(request)
            guard isCurrentMemoryLink(linkID, origin: origin) else { return }
            guard
                let source = catalog.sources.first(where: {
                    $0.isMarkdown && URL(filePath: $0.location).standardizedFileURL.path == url.standardizedFileURL.path
                })
            else { throw CoreFailure.failed("This link is not a discovered local memory file.") }
            var next = request
            next.sourceID = source.id
            let generations = Dictionary(uniqueKeysWithValues: editors.map { ($0.id, $0.generation) })
            let read = try await client.memoryRead(next)
            guard isCurrentMemoryLink(linkID, origin: origin) else { return }
            openMemory(read, request: next, generations: generations)
            selected?.navigate(to: url)
        } catch {
            guard isCurrentMemoryLink(linkID, origin: origin) else { return }
            throw error
        }
    }

    func refreshMemory(_ editor: FileEditorModel, client: CoreClient) async throws {
        guard let request = editor.memoryRequest else { return }
        let generation = editor.generation
        let read = try await client.memoryRead(request)
        guard !Task.isCancelled, editor.generation == generation,
            editors.contains(where: { $0 === editor })
        else { return }
        editor.useMemorySource(request, source: read.source)
        editor.receive(read.preview)
    }

    private func openMemory(_ read: CoreMemoryRead, request: CoreMemoryRequest, generations: [UUID: UUID]) {
        let editor = editors.first(where: { $0.path == read.preview.path })
        if let editor, let generation = generations[editor.id], editor.generation != generation {
            editor.useMemorySource(request, source: read.source)
            selectedID = editor.id
            return
        }
        openMemory(read, request: request)
    }

    private func isCurrentMemoryLink(_ linkID: UUID, origin: UUID?) -> Bool {
        !Task.isCancelled && memoryLinkID == linkID && selectedID == origin
            && (origin == nil || editors.contains(where: { $0.id == origin }))
    }

    func showWorkflows() { selectedID = nil }

    @discardableResult
    func close(_ id: UUID) -> Bool {
        guard let index = editors.firstIndex(where: { $0.id == id }), editors[index].confirmDiscard() else {
            return false
        }
        editors.remove(at: index)
        if selectedID == id {
            selectedID = editors.isEmpty ? nil : editors[min(index, editors.count - 1)].id
        }
        return true
    }

    @discardableResult
    func closeAll() -> Bool {
        // Do not remove any buffer until all confirmations succeed.
        guard editors.allSatisfy({ $0.confirmDiscard() }) else { return false }
        discardAll()
        return true
    }

    func discardAll() {
        guard !isSaving else { return }
        editors.removeAll()
        selectedID = nil
    }
}
