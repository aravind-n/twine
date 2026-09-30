import AppKit
import SwiftUI

/// Closing the window also closes its folder's processes, even when the app remains running.
struct FolderWindowLifetime: NSViewRepresentable {
    let coreClient: CoreClient
    let folder: String
    let editor: FileEditorModel

    func makeNSView(context: Context) -> FolderWindowObserver {
        FolderWindowObserver(coreClient: coreClient, folder: folder, editor: editor)
    }

    func updateNSView(_ nsView: FolderWindowObserver, context: Context) {
        nsView.window?.isDocumentEdited = editor.isDirty
    }
}

final class FolderWindowObserver: NSView {
    private let coreClient: CoreClient
    private let folder: String
    private weak var observedWindow: NSWindow?
    private let editor: FileEditorModel

    init(coreClient: CoreClient, folder: String, editor: FileEditorModel) {
        self.coreClient = coreClient
        self.folder = folder
        self.editor = editor
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observedWindow = window
        window?.isDocumentEdited = editor.isDirty
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let observedWindow, notification.object as? NSWindow === observedWindow else { return }
        editor.discardAndClose()
        Task { await coreClient.perform(.closeFolderIfOpen(path: folder)) }
    }
}
