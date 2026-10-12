import AppKit
import SwiftUI

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
            Text("Press ⌘S to save. Saved settings apply immediately to all open folders.")
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
