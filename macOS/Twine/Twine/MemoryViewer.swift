import SwiftUI

struct MemoryViewer: View {
    @Environment(CoreClient.self) private var client
    let folder: String?
    let close: () -> Void
    @State private var model = MemoryModel()

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
    }

    private var content: some View {
        VStack(spacing: 0) {
            MemoryHeader(model: model, close: close)
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
                            MemorySourceList(model: model).frame(minWidth: 260, idealWidth: 330, maxWidth: 450)
                            MemoryReader(model: model).frame(minWidth: 220)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            if model.pane == .reader {
                                Button("Sources", systemImage: "chevron.left") { model.pane = .sources }
                                    .padding(10).accessibilityIdentifier("showMemorySources")
                                MemoryReader(model: model)
                            } else {
                                MemorySourceList(model: model)
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                if model.state == .loading { ProgressView().controlSize(.mini) }
                Text("\(model.filteredSources.count) sources")
                Spacer()
                Menu("Checked locations") {
                    ForEach(Array((model.catalog?.diagnostics ?? []).enumerated()), id: \.offset) { Text($0.element) }
                }.accessibilityIdentifier("memoryLocations")
            }.font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .background(.windowBackground).clipShape(.rect(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).stroke(.hairline, lineWidth: 1) }
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
    var body: some View {
        Group {
            if showsMemories {
                MemoryViewer(folder: nil, close: { showsMemories = false })
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
