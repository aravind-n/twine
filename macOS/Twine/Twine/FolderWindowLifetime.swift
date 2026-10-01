import AppKit
import SwiftUI

/// Closing the window also closes its folder's processes, even when the app remains running.
struct FolderWindowLifetime: NSViewRepresentable {
    let coreClient: CoreClient
    let folder: String
    let tabs: FileTabsModel

    func makeNSView(context: Context) -> FolderWindowObserver {
        FolderWindowObserver(coreClient: coreClient, folder: folder, tabs: tabs)
    }

    func updateNSView(_ nsView: FolderWindowObserver, context: Context) {
        nsView.window?.isDocumentEdited = tabs.isDirty
    }
}

final class FolderWindowObserver: NSView {
    private let coreClient: CoreClient
    private let folder: String
    private weak var observedWindow: NSWindow?
    private let tabs: FileTabsModel

    init(coreClient: CoreClient, folder: String, tabs: FileTabsModel) {
        self.coreClient = coreClient
        self.folder = folder
        self.tabs = tabs
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
        window?.isDocumentEdited = tabs.isDirty
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let observedWindow, notification.object as? NSWindow === observedWindow else { return }
        tabs.discardAll()
        Task { await coreClient.perform(.closeFolderIfOpen(path: folder)) }
    }
}
