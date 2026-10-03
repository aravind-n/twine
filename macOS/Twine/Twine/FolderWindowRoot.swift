import SwiftUI

struct FolderWindowRoot: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(WorkflowLayouts.self) private var layouts
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
            .background { FolderWindowLifetime(session: session, windows: windows).frame(width: 0, height: 0) }
            .task {
                await layouts.load()
                await windows.start(session) { openWindow(id: "folder", value: $0) }
            }
    }
}

#Preview {
    FolderWindowRoot(
        id: UUID(), windows: FolderWindows(dataDirectory: .temporaryDirectory.appending(path: "TwinePreview"))
    )
    .environment(WorkflowLayouts(fileURL: .temporaryDirectory.appending(path: "twine-preview-layouts.json")))
    .environment(HarnessModelCatalog())
}
