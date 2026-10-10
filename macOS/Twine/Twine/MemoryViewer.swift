import SwiftUI

struct MemoryViewer: View {
    @Environment(CoreClient.self) private var client
    let folder: String?
    let close: () -> Void
    @Bindable var model: MemoryModel

    var body: some View {
        GeometryReader { geometry in
            WorkspaceViewport(contentHeight: max(460, geometry.size.height)) {
                content.frame(height: max(460, geometry.size.height))
            }
        }
        .task(id: CatalogKey(folder: folder, refresh: model.refreshID)) {
            await model.load(client: client, folder: folder)
        }
        .task(id: SelectionKey(id: model.selectedID, generation: model.generation)) {
            await model.read(client: client, folder: folder)
        }
        .onChange(of: model.filteredSources.map(\.id)) { model.reconcileSelection() }
        .onChange(of: model.selectedID) {
            model.revealSelection()
        }
        .accessibilityIdentifier("memoryViewer")
        .alert(
            "Couldn't Open Link",
            isPresented: Binding(
                get: { model.linkFailure != nil }, set: { if !$0 { model.linkFailure = nil } }
            )
        ) {
            Button("OK") { model.linkFailure = nil }
        } message: {
            Text(model.linkFailure ?? "")
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            MemoryHeader(model: model, close: close)
            Divider()
            MemoryFilters(model: model)
            Divider()
            if case .failed(let message) = model.state {
                ContentUnavailableView(
                    "Couldn't Discover Memories", systemImage: "exclamationmark.triangle",
                    description: Text(message))
            } else {
                GeometryReader { geometry in
                    if geometry.size.width >= 600 {
                        HSplitView {
                            MemorySourceList(model: model, folder: folder).frame(
                                minWidth: 280, idealWidth: 280, maxWidth: 360)
                            MemoryReader(model: model, folder: folder).frame(minWidth: 280)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            if model.pane == .reader {
                                Button("Sources", systemImage: "chevron.left") { model.pane = .sources }
                                    .padding(10).accessibilityIdentifier("showMemorySources")
                                MemoryReader(model: model, folder: folder)
                            } else {
                                MemorySourceList(model: model, folder: folder)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                if model.state == .loading { ProgressView().controlSize(.mini) }
                Text("\(model.filteredSources.count) sources · Local files")
                Spacer()
                Menu("Checked locations") {
                    ForEach(Array((model.catalog?.diagnostics ?? []).enumerated()), id: \.offset) { Text($0.element) }
                }.menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("memoryLocations")
            }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(MemoryPalette.document).clipShape(.rect(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).stroke(.hairline, lineWidth: 1) }
        .padding(14)
    }
}

private struct CatalogKey: Equatable {
    let folder: String?
    let refresh: UUID
}
private struct SelectionKey: Equatable {
    let id: String?
    let generation: UUID
}

struct MemoryViewPreview: View {
    @State private var showsMemories = true
    @State private var model = MemoryModel()
    var body: some View {
        Group {
            if showsMemories {
                MemoryViewer(folder: nil, close: { showsMemories = false }, model: model)
            } else {
                Button("Show Memories") { showsMemories = true }
            }
        }
        .environment(CoreClient(transport: CoreWorker(dataDirectory: AppPaths.previewDirectory)))
        .environment(WorkflowLayouts(fileURL: AppPaths.previewDirectory.appending(path: "memory-layouts.json")))
        .environment(FileTabsModel())
        .environment(TraceTerminalNavigation())
        .environment(HarnessModelCatalog())
        .frame(width: 1000, height: 650)
    }
}

#Preview { MemoryViewPreview() }
