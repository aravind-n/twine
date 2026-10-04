import AppKit
import SwiftUI

/// Each presentation follows its own display, including when a window moves between screens.
struct PresentationScreen: NSViewRepresentable {
    let update: (CGSize) -> Void

    func makeNSView(context: Context) -> ScreenView { ScreenView(update: update) }
    func updateNSView(_ view: ScreenView, context: Context) { view.update = update }

    final class ScreenView: NSView {
        var update: (CGSize) -> Void
        private var updateTask: Task<Void, Never>?

        init(update: @escaping (CGSize) -> Void) {
            self.update = update
            super.init(frame: .zero)
            NotificationCenter.default.addObserver(
                self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification,
                object: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            publishScreen()
        }

        @objc private func screenChanged(_ notification: Notification) {
            if notification.name == NSWindow.didChangeScreenNotification {
                guard notification.object as? NSWindow === window else { return }
            }
            publishScreen()
        }

        private func publishScreen() {
            updateTask?.cancel()
            updateTask = Task { [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, let screen = window?.screen else { return }
                update(screen.visibleFrame.size)
            }
        }

        isolated deinit {
            updateTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }
    }
}
