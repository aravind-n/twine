import AppKit
import OSLog
import Observation
import SwiftUI

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

struct SettingsView: View {
    let settings: SettingsPopup
    let windows: FolderWindows
    @Environment(\.appZoomMaximumPresentationSize) private var maximumSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done", action: settings.close)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("closeSettings")
            }
            Text("Saved settings apply immediately to all open folders.")
                .font(.caption).foregroundStyle(.secondary)
            if let editor = settings.editor {
                FileViewer(
                    path: editor.path, folder: editor.folder, failure: nil,
                    isVisible: settings.isPresented, openFile: { _ in },
                    didSave: { try await windows.reloadConfig() }
                )
                .environment(editor)
                .environment(settings.coreClient)
            } else if let failure = settings.failure {
                ContentUnavailableView {
                    Label("Couldn't Open Settings", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try Again") { Task { await settings.load() } }
                }
            } else {
                ProgressView("Loading settings…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
        .frame(width: min(780, maximumSize.width), height: min(600, maximumSize.height))
        .background { SettingsPopupHost().frame(width: 0, height: 0) }
        .interactiveDismissDisabled()
        .task { await settings.load() }
    }
}

/// Let the app's quit delegate protect this buffer rather than silently blocking quit at the sheet.
private struct SettingsPopupHost: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsPopupObserver { SettingsPopupObserver(frame: .zero) }
    func updateNSView(_ nsView: SettingsPopupObserver, context: Context) {}
}

private final class SettingsPopupObserver: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.preventsApplicationTerminationWhenModal = false
    }
}
