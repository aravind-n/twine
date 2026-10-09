import AppKit
import OSLog
import Observation

private let fileEditorLogger = Logger(subsystem: "com.twineproject.Twine", category: "file-editor")

/// One open file's editing buffer; twine-core supplies disk versions and performs every save.
@Observable
final class FileEditorModel: Identifiable {
    let id = UUID()
    let path: String
    let folder: String
    let isConfigFile: Bool
    private(set) var baseline: FilePreview?
    private(set) var diskFile: FilePreview?
    private(set) var navigationURL: URL?
    private(set) var navigationID = UUID()
    var text = "" {
        didSet {
            if oldValue != text { autosaveID = UUID() }
            if oldValue != baseline?.text && text == baseline?.text { generation = UUID() }
        }
    }
    private(set) var loadID = UUID()
    private(set) var generation = UUID()
    private(set) var saveID: UUID?
    private(set) var autosaveID = UUID()
    private(set) var autosavePaused = false
    private var pendingSave: FileSaveRequest?
    var conflict: FilePreview?
    var failure: String?

    var isDirty: Bool { baseline?.status == .text && text != baseline?.text }
    var isSaving: Bool { pendingSave != nil }
    var canSave: Bool { isDirty && !isSaving && baseline?.version != nil }
    var canAutosave: Bool { !isConfigFile && !autosavePaused && conflict == nil && failure == nil && canSave }

    init(path: String, folder: String, isConfigFile: Bool = false) {
        self.path = path
        self.folder = folder
        self.isConfigFile = isConfigFile
    }

    func navigate(to url: URL) {
        navigationURL = url
        navigationID = UUID()
    }

    func receive(_ preview: FilePreview?) {
        guard let preview, preview.path == path else { return }
        diskFile = preview
        guard !isDirty, !isSaving, conflict == nil,
            preview != baseline
        else { return }
        replace(with: preview)
    }

    /// The view cancels this debounce on each edit; the revision also rejects stale requests.
    func autosave(after delay: Duration = .milliseconds(500)) async {
        guard canAutosave else { return }
        let revision = autosaveID
        do {
            try await Task.sleep(for: delay)
            try Task.checkCancellation()
        } catch {
            return
        }
        guard revision == autosaveID, canAutosave else { return }
        requestSave()
    }

    func requestSave(overwrite: Bool = false) {
        guard canSave, let version = baseline?.version else { return }
        pendingSave = FileSaveRequest(
            folder: folder, path: path, text: text, expectedVersion: version, overwrite: overwrite)
        conflict = nil
        failure = nil
        generation = UUID()
        saveID = UUID()
    }

    func savePending(client: CoreClient, didSave: (() async throws -> Void)? = nil) async {
        guard let request = pendingSave else { return }
        do {
            let result = try await (isConfigFile ? client.saveConfigFile(request) : client.saveFile(request))
            switch result.status {
            case .saved:
                guard let file = result.file, file.path == path, file.version != nil else {
                    throw CoreFailure.unexpectedCommandResult
                }
                baseline = file
                diskFile = file
                autosavePaused = false
                try await didSave?()
            case .conflict:
                guard let file = result.file, file.path == path else { throw CoreFailure.unexpectedCommandResult }
                conflict = file
                autosavePaused = true
            case .failed:
                failure = result.message ?? "The file could not be saved."
                autosavePaused = true
            }
        } catch {
            failure = error.localizedDescription
            autosavePaused = true
            fileEditorLogger.error("File save failed: \(error.localizedDescription, privacy: .public)")
        }
        pendingSave = nil
        generation = UUID()
        // Edits made during the write need a new debounce against the saved version.
        autosaveID = UUID()
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
        let name = URL(filePath: path).lastPathComponent
        alert.informativeText = "Changes to “\(name)” will be lost. Cancel to keep editing or save with ⌘S."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func replace(with preview: FilePreview) {
        autosavePaused = false
        baseline = preview
        text = preview.text ?? ""
        loadID = UUID()
    }
}
