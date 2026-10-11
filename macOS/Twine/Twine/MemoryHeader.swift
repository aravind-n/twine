import SwiftUI

struct MemoryHeader: View {
    @Bindable var model: MemoryModel
    let isPresented: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if model.isExpanded && isPresented {
                    model.isExpanded = false
                } else {
                    model.isExpanded = true
                    open()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                    Image(systemName: "brain").foregroundStyle(.secondary)
                    Text("Memories").fontWeight(.semibold)
                    Spacer(minLength: 0)
                }.contentShape(.rect).frame(height: 42)
            }.buttonStyle(.plain).accessibilityIdentifier("memoryEntry-outline")
                .accessibilityValue(model.isExpanded ? "Expanded" : "Collapsed")
                .help(model.isExpanded && isPresented ? "Collapse Memories" : "Open Memories")
            if model.isExpanded {
                Button("Refresh memories", systemImage: "arrow.clockwise", action: model.refresh)
                    .buttonStyle(.plain).labelStyle(.iconOnly).help("Rescan local memory sources")
                    .accessibilityIdentifier("refreshMemories")
            }
        }.font(.system(size: 12)).padding(.horizontal, 14)
    }
}

#Preview { MemoryViewPreview() }
