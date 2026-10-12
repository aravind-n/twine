import AppKit
import OSLog
import Observation

private let settingsLogger = Logger(subsystem: "com.twineproject.Twine", category: "settings")

/// One app-wide editing buffer, presented as a sheet in the folder window that opened it.
@Observable
final class SettingsPopup {
    let coreClient: CoreClient
    private(set) var editor: FileEditorModel?
    private(set) var failure: String?
    private(set) var presentedWindowID: UUID?
    @ObservationIgnored private weak var source: FolderWindowSession?
    var isPresented: Bool { presentedWindowID != nil }

    init(dataDirectory: URL) {
        coreClient = CoreClient(transport: CoreWorker(dataDirectory: dataDirectory))
    }

    func show(in session: FolderWindowSession) {
        if isPresented {
            (source?.window?.attachedSheet ?? source?.window)?.makeKeyAndOrderFront(nil)
            return
        }
        source = session
        presentedWindowID = session.id
    }

    func load() async {
        failure = nil
        do {
            let file = try await coreClient.configFile()
            try Task.checkCancellation()
            guard isPresented else { return }
            let editor = FileEditorModel(
                path: file.path, folder: URL(filePath: file.path).deletingLastPathComponent().path,
                isConfigFile: true)
            editor.receive(file)
            self.editor = editor
        } catch is CancellationError {
            return
        } catch {
            failure = error.localizedDescription
            settingsLogger.error("Settings file could not be opened: \(error.localizedDescription, privacy: .public)")
        }
    }

    func close() {
        guard confirmDiscard() else { return }
        presentedWindowID = nil
        editor = nil
        failure = nil
        source = nil
    }

    func confirmDiscard() -> Bool { editor?.confirmDiscard() ?? true }

}
