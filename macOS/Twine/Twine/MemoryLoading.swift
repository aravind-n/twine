import SwiftUI

/// Keep discovery attached to the folder while memories use the normal file tabs.
struct MemoryLoading: ViewModifier {
    @Environment(CoreClient.self) private var client
    @Environment(FileTabsModel.self) private var tabs
    let folder: String
    let model: MemoryModel

    func body(content: Content) -> some View {
        content
            .task(id: CatalogKey(folder: folder, refresh: model.refreshID, active: model.isExpanded)) {
                guard model.isExpanded else { return }
                await model.load(client: client, folder: folder)
                guard !Task.isCancelled, model.state == .available, let editor = tabs.selected,
                    let request = editor.memoryRequest,
                    request.folder == folder
                else { return }
                do {
                    try await tabs.refreshMemory(editor, client: client)
                } catch {
                    guard !Task.isCancelled, tabs.selected === editor else { return }
                    model.openFailure = error.localizedDescription
                }
            }
            .alert(
                "Couldn't Open Memory",
                isPresented: Binding(get: { model.openFailure != nil }, set: { if !$0 { model.openFailure = nil } })
            ) {
                Button("OK") { model.openFailure = nil }
            } message: {
                Text(model.openFailure ?? "")
            }
    }
}

private struct CatalogKey: Equatable {
    let folder: String
    let refresh: UUID
    let active: Bool
}
