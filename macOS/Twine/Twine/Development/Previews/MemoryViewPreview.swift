import SwiftUI

struct MemoryViewPreview: View {
    @State private var model = MemoryModel()
    @State private var tabs = FileTabsModel()
    @State private var client = CoreClient(transport: CoreWorker(dataDirectory: AppPaths.previewDirectory))

    var body: some View {
        HStack(spacing: 0) {
            MemorySidebar(
                model: model, folder: NSHomeDirectory(), contentHeight: 650 - SidebarLayout.sectionHeaderHeight
            ) {
                guard let source = model.selected else { return }
                Task {
                    try? await tabs.openMemory(
                        request: model.request(folder: NSHomeDirectory(), sourceID: source.id), client: client)
                }
            }.frame(width: 285)
            VStack(spacing: 0) {
                WorkflowTabs(
                    workflows: [], selectedID: nil, select: { _ in }, close: { _ in },
                    cancelAgent: { _ in }, create: {})
                if let editor = tabs.selected {
                    FileViewer(
                        path: editor.path, folder: editor.folder, failure: nil, isVisible: true,
                        openFile: { _ in }
                    ).environment(editor)
                } else {
                    ContentUnavailableView("Select a Source", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .onAppear {
            model.isExpanded = true
            model.scope = .global
        }
        .modifier(MemoryLoading(folder: NSHomeDirectory(), model: model))
        .environment(client)
        .environment(tabs)
        .frame(width: 1000, height: 650)
    }
}

#Preview { MemoryViewPreview() }
