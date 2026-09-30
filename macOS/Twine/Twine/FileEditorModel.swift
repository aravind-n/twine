import AppKit
import OSLog
import Observation

private let fileEditorLogger = Logger(subsystem: "com.twineproject.Twine", category: "file-editor")

/// A single transient editing buffer; twine-core supplies disk versions and performs every save.
@Observable
final class FileEditorModel {
    private(set) var path: String?
    private(set) var folder: String?
    private(set) var baseline: FilePreview?
    var text = "" {
        didSet {
            if oldValue != baseline?.text && text == baseline?.text { generation = UUID() }
        }
    }
    private(set) var loadID = UUID()
    private(set) var generation = UUID()
    private(set) var saveID: UUID?
    private var pendingSave: FileSaveRequest?
    var conflict: FilePreview?
    var failure: String?

    var isDirty: Bool { baseline?.status == .text && text != baseline?.text }
    var isSaving: Bool { pendingSave != nil }
    var canSave: Bool { isDirty && !isSaving && baseline?.version != nil }

    @discardableResult
    func select(_ path: String?, folder: String? = nil) -> Bool {
        guard path != self.path || folder != self.folder else { return true }
        guard confirmDiscard() else { return false }
        self.path = path
        self.folder = folder
        baseline = nil
        text = ""
        conflict = nil
        failure = nil
        loadID = UUID()
        generation = UUID()
        return true
    }

    func receive(_ preview: FilePreview?) {
        guard let preview, preview.path == path, !isDirty, !isSaving, conflict == nil,
            preview != baseline
        else { return }
        replace(with: preview)
    }

    func discardAndClose() {
        guard !isSaving else { return }
        text = baseline?.text ?? ""
        select(nil)
    }

    func requestSave(overwrite: Bool = false) {
        guard canSave, let folder, let path, let version = baseline?.version else { return }
        pendingSave = FileSaveRequest(
            folder: folder, path: path, text: text, expectedVersion: version, overwrite: overwrite)
        conflict = nil
        failure = nil
        generation = UUID()
        saveID = UUID()
    }

    func savePending(client: CoreClient) async {
        guard let request = pendingSave else { return }
        do {
            let result = try await client.saveFile(request)
            switch result.status {
            case .saved:
                guard let file = result.file, file.path == path, file.version != nil else {
                    throw CoreFailure.unexpectedCommandResult
                }
                baseline = file
            case .conflict:
                guard let file = result.file, file.path == path else { throw CoreFailure.unexpectedCommandResult }
                conflict = file
            case .failed:
                failure = result.message ?? "The file could not be saved."
            }
        } catch {
            failure = error.localizedDescription
            fileEditorLogger.error("File save failed: \(error.localizedDescription, privacy: .public)")
        }
        pendingSave = nil
        generation = UUID()
    }

    func reloadConflict(_ conflict: FilePreview) {
        replace(with: conflict)
        self.conflict = nil
        failure = nil
        generation = UUID()
    }

    /// Used by navigation, folder/window close, and quit so none can silently discard this buffer.
    func confirmDiscard() -> Bool {
        if isSaving {
            let alert = NSAlert()
            alert.messageText = "Saving File"
            alert.informativeText = "Wait for the save to finish before leaving this file."
            alert.runModal()
            return false
        }
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        let name = path.map { URL(filePath: $0).lastPathComponent } ?? "this file"
        alert.informativeText = "Changes to “\(name)” will be lost. Cancel to keep editing or save with ⌘S."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func replace(with preview: FilePreview) {
        baseline = preview
        text = preview.text ?? ""
        loadID = UUID()
    }
}
