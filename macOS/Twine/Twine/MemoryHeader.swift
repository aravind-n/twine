import SwiftUI

struct MemoryHeader: View {
    @Bindable var model: MemoryModel
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Memories").font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
            MemoryBadge("Local", tint: .green)
            Button("Refresh", systemImage: "arrow.clockwise", action: model.refresh)
                .labelStyle(.iconOnly).help("Rescan local memory sources")
                .accessibilityIdentifier("refreshMemories")
            Button("Return to Workflows", systemImage: "terminal", action: close)
                .labelStyle(.iconOnly).help("Return to workflows")
                .accessibilityIdentifier("closeMemories")
        }.controlSize(.small).padding(.horizontal, 14).padding(.vertical, 12)
    }
}

#Preview { MemoryViewPreview() }
