import SwiftUI

struct FolderWindowRoot: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(WorkflowLayouts.self) private var layouts
    @Environment(SettingsPopup.self) private var settings
    @State private var session: FolderWindowSession
    let windows: FolderWindows

    init(id: UUID, windows: FolderWindows) {
        self.windows = windows
        _session = State(initialValue: windows.session(id: id))
    }

    var body: some View {
        ContentView(session: session, windows: windows)
            .environment(session.coreClient)
            .environment(session.tabs)
            .focusedSceneValue(\.folderWindow, session)
            .preferredColorScheme(preferredColorScheme)
            .sheet(
                isPresented: Binding(
                    get: { settings.presentedWindowID == session.id },
                    // Explicit popup actions and the quit delegate own discard confirmation.
                    set: { _ in })
            ) {
                SettingsView(settings: settings, windows: windows).appZoom()
            }
            .background { FolderWindowLifetime(session: session, windows: windows).frame(width: 0, height: 0) }
            .task {
                await layouts.load()
                await windows.start(session) { openWindow(id: "folder", value: $0) }
            }
    }

    private var preferredColorScheme: ColorScheme? {
        switch session.coreClient.snapshot?.config.appearance.colorScheme {
        case .light: .light
        case .dark: .dark
        case .system, nil: nil
        }
    }
}

#Preview {
    FolderWindowRoot(
        id: UUID(), windows: FolderWindows(dataDirectory: .temporaryDirectory.appending(path: "TwinePreview"))
    )
    .environment(WorkflowLayouts(fileURL: .temporaryDirectory.appending(path: "twine-preview-layouts.json")))
    .environment(HarnessModelCatalog())
    .environment(SettingsPopup(dataDirectory: .temporaryDirectory.appending(path: "TwinePreview")))
}
