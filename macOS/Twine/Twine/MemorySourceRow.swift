import SwiftUI

struct MemorySourceRow: View {
    let source: CoreMemorySource

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: source.kind == .storeStatus ? "externaldrive" : "doc.text")
                    .foregroundStyle(source.harness == .codex ? Color.blue : Color.orange)
                Text(source.title).fontWeight(.medium).lineLimit(2)
            }
            Text("\(source.harness.title) · \(source.scope.title)")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text(source.kind.title)
                if source.example { Text("Example").foregroundStyle(.orange) }
            }.font(.caption2).foregroundStyle(.secondary)
            Text(source.shortPath).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .font(.caption).padding(.vertical, 5)
        .help(source.location)
        .accessibilityIdentifier("memorySource-\(source.id)")
    }
}

#Preview { MemoryViewPreview() }
