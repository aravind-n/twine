import SwiftUI

struct MemoryHeader: View {
    @Bindable var model: MemoryModel

    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                    Text("Memories").fontWeight(.semibold)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
                .padding(.trailing, model.isExpanded ? 6 : 14)
                .frame(height: 42)
                .contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("memoryEntry-outline")
                .accessibilityValue(model.isExpanded ? "Expanded" : "Collapsed")
                .help(model.isExpanded ? "Collapse Memories" : "Open Memories")
            if model.isExpanded {
                Button(action: model.refresh) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 40, height: 42)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain).help("Rescan local memory sources")
                .accessibilityLabel("Refresh memories")
                .accessibilityIdentifier("refreshMemories")
            }
        }.font(.system(size: 12))
    }
}

#Preview { MemoryViewPreview() }
