import Foundation
import Observation

/// Open file tabs are presentation state. Each editor keeps its own buffer and disk version.
@Observable
final class FileTabsModel {
    private(set) var editors: [FileEditorModel] = []
    private(set) var selectedID: UUID?

    var selected: FileEditorModel? { editors.first { $0.id == selectedID } }
    var isDirty: Bool { editors.contains { $0.isDirty } }
    var isSaving: Bool { editors.contains { $0.isSaving } }

    @discardableResult
    func open(path: String, folder: String, navigationURL: URL? = nil) -> FileEditorModel {
        let editor: FileEditorModel
        if let existing = editors.first(where: { $0.path == path && $0.folder == folder }) {
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
