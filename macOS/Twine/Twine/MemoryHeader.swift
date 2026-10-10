import SwiftUI

struct MemoryHeader: View {
    @Bindable var model: MemoryModel
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("Memories", systemImage: "brain").font(.headline)
            Text("Local · Read-only").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Refresh", systemImage: "arrow.clockwise", action: model.refresh)
                .labelStyle(.iconOnly).help("Rescan local memory sources")
                .accessibilityIdentifier("refreshMemories")
            Button("Return to Workflows", systemImage: "terminal", action: close)
                .labelStyle(.iconOnly).help("Return to workflows")
                .accessibilityIdentifier("closeMemories")
        }.padding(14)
    }
}

#Preview { MemoryViewPreview() }
