import AppKit
import SwiftUI

/// Closing the window also closes its folder's processes, even when the app remains running.
struct FolderWindowLifetime: NSViewRepresentable {
    let bridgeClient: BridgeClient
    let folder: String

    func makeNSView(context: Context) -> FolderWindowObserver {
        FolderWindowObserver(bridgeClient: bridgeClient, folder: folder)
    }

    func updateNSView(_ nsView: FolderWindowObserver, context: Context) {}
}

final class FolderWindowObserver: NSView {
    private let bridgeClient: BridgeClient
    private let folder: String
    private weak var observedWindow: NSWindow?

    init(bridgeClient: BridgeClient, folder: String) {
        self.bridgeClient = bridgeClient
        self.folder = folder
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
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let observedWindow, notification.object as? NSWindow === observedWindow else { return }
        Task { await bridgeClient.perform(.closeFolderIfOpen(path: folder)) }
    }
}
