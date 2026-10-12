import AppKit
import SwiftUI

/// Closing a window ends only its runtime. App quit keeps the core's folder restore flags.
struct FolderWindowLifetime: NSViewRepresentable {
    let session: FolderWindowSession
    let windows: FolderWindows

    func makeNSView(context: Context) -> FolderWindowObserver {
        FolderWindowObserver(session: session, windows: windows)
    }

    func updateNSView(_ nsView: FolderWindowObserver, context: Context) {
        nsView.window?.isDocumentEdited = session.tabs.isDirty
    }
}

final class FolderWindowObserver: NSView {
    private let session: FolderWindowSession
    private let windows: FolderWindows
    private weak var observedWindow: NSWindow?

    init(session: FolderWindowSession, windows: FolderWindows) {
        self.session = session
        self.windows = windows
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftUI can briefly detach the observer while reconciling content. Keep the last live
        // window so folder routing and the close notification still refer to its window.
        guard let window else { return }
        observedWindow = window
        session.window = window
        window.isDocumentEdited = session.tabs.isDirty
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let observedWindow, notification.object as? NSWindow === observedWindow else { return }
        windows.retire(session)
    }
}
