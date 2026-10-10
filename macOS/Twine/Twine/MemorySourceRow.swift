import SwiftUI

struct MemorySourceRow: View {
    let source: CoreMemorySource
    var folder: String?

    private var filename: String {
        if let folder, source.scope == .folder, source.location.hasPrefix(folder + "/") {
            return String(source.location.dropFirst(folder.count + 1))
        }
        return source.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(source.harness == .codex ? Color.blue : .orange).frame(width: 5, height: 5)
                Text(filename).font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 4) {
                MemoryBadge(source.harness.title, tint: source.harness == .codex ? .blue : .orange)
                MemoryBadge(source.scope.title)
                if source.example { MemoryBadge("Example", tint: .orange) }
            }
        }
        .padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle()).help(source.location)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(filename), \(source.harness.title), \(source.scope.title)")
        .accessibilityIdentifier("memorySource-\(source.id)")
    }
}

#Preview { MemoryViewPreview() }
