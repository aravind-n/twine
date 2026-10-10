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
    private(set) var memoryRequest: CoreMemoryRequest?
    var requiresExplicitSave: Bool { isConfigFile || memoryRequest != nil }
    private(set) var sourceRequestID: UUID?
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
    private(set) var autosaveSettings = CoreEditorConfig()
    private var pendingSave: FileSaveRequest?
    private var queuedSave: (text: String, overwrite: Bool)?
    var conflict: FilePreview?
    var failure: String?

    var isDirty: Bool { baseline?.status == .text && text != baseline?.text }
    var isSaving: Bool { pendingSave != nil }
    var canSave: Bool {
        baseline?.version != nil && (isSaving ? text != (queuedSave?.text ?? pendingSave?.text) : isDirty)
    }
    var canAutosave: Bool {
        autosaveSettings.autosave && !requiresExplicitSave && !isSaving && !autosavePaused
            && conflict == nil && failure == nil && canSave
    }

    init(path: String, folder: String, isConfigFile: Bool = false, memoryRequest: CoreMemoryRequest? = nil) {
        self.path = path
        self.folder = folder
        self.isConfigFile = isConfigFile
        self.memoryRequest = memoryRequest
    }

    func editSource() { sourceRequestID = UUID() }

    func useMemorySource(_ request: CoreMemoryRequest) {
        memoryRequest = request
        autosaveID = UUID()
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

    func configureAutosave(_ settings: CoreEditorConfig) {
        guard settings != autosaveSettings else { return }
        autosaveSettings = settings
        autosaveID = UUID()
    }

    /// The view cancels this debounce on each edit or setting change; reject stale requests too.
    func autosave(after delay: Duration? = nil) async {
        guard canAutosave else { return }
        let revision = autosaveID
        do {
            try await Task.sleep(for: delay ?? .milliseconds(autosaveSettings.autosaveDelayMilliseconds))
            try Task.checkCancellation()
        } catch {
            return
        }
        guard revision == autosaveID, canAutosave else { return }
        requestSave()
    }

    func requestSave(overwrite: Bool = false) {
        guard canSave, let version = baseline?.version else { return }
        if isSaving {
            queuedSave = (text, overwrite)
            return
        }
        enqueueSave(text: text, version: version, overwrite: overwrite)
    }

    private func enqueueSave(text: String, version: FileVersion, overwrite: Bool) {
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
            let result = try await save(request, client: client)
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
        let queued = queuedSave
        queuedSave = nil
        guard let queued, conflict == nil, failure == nil, let version = baseline?.version,
            queued.text != baseline?.text
        else { return }
        enqueueSave(text: queued.text, version: version, overwrite: queued.overwrite)
    }

    func reloadConflict(_ conflict: FilePreview) {
        replace(with: conflict)
        self.conflict = nil
        failure = nil
        generation = UUID()
    }

    private func save(_ request: FileSaveRequest, client: CoreClient) async throws -> FileSaveResult {
        if let memoryRequest {
            return try await client.memorySave(
                .init(
                    source: memoryRequest, text: request.text,
                    expectedVersion: request.expectedVersion, overwrite: request.overwrite))
        }
        return try await (isConfigFile ? client.saveConfigFile(request) : client.saveFile(request))
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
