import SwiftUI

/// Keep discovery attached to the folder, so opening an editor doesn't discard sidebar state.
struct MemoryLoading: ViewModifier {
    @Environment(CoreClient.self) private var client
    let folder: String
    let model: MemoryModel
    let isPresented: Bool

    func body(content: Content) -> some View {
        content
            .task(id: CatalogKey(folder: folder, refresh: model.refreshID, active: model.isExpanded || isPresented)) {
                guard model.isExpanded || isPresented else { return }
                await model.load(client: client, folder: folder)
            }
            .task(id: SelectionKey(id: model.selectedID, generation: model.generation, active: isPresented)) {
                guard isPresented else { return }
                await model.read(client: client, folder: folder)
            }
            .onChange(of: isPresented) {
                // Returning from the normal editor must show its latest saved contents.
                if isPresented, model.catalog != nil { model.refresh() }
            }
            .onChange(of: model.selectedID) { model.revealSelection() }
    }
}

private struct CatalogKey: Equatable {
    let folder: String
    let refresh: UUID
    let active: Bool
}

private struct SelectionKey: Equatable {
    let id: String?
    let generation: UUID
    let active: Bool
}
