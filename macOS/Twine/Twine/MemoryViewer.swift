import SwiftUI

struct MemoryViewer: View {
    let folder: String?
    @Bindable var model: MemoryModel

    var body: some View {
        Group {
            if case .failed(let message) = model.state {
                ContentUnavailableView(
                    "Couldn't Discover Memories", systemImage: "exclamationmark.triangle",
                    description: Text(message))
            } else {
                MemoryReader(model: model, folder: folder)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MemoryPalette.document).clipShape(.rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.hairline, lineWidth: 1) }
        .padding(10)
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
}

struct MemoryViewPreview: View {
    @State private var model = MemoryModel()
    var body: some View {
        HStack(spacing: 0) {
            MemorySidebar(model: model, folder: NSHomeDirectory(), isPresented: true, open: {})
                .frame(width: 285)
            MemoryViewer(folder: NSHomeDirectory(), model: model)
        }
        .onAppear {
            model.isExpanded = true
            model.scope = .global
        }
        .modifier(MemoryLoading(folder: NSHomeDirectory(), model: model, isPresented: true))
        .environment(CoreClient(transport: CoreWorker(dataDirectory: AppPaths.previewDirectory)))
        .environment(WorkflowLayouts(fileURL: AppPaths.previewDirectory.appending(path: "memory-layouts.json")))
        .environment(FileTabsModel())
        .environment(TraceTerminalNavigation())
        .environment(HarnessModelCatalog())
        .frame(width: 1000, height: 650)
    }
}

#Preview { MemoryViewPreview() }
