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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: source.isMarkdown ? "doc.text" : "doc")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(filename).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Circle().fill(source.harness == .codex ? Color.blue : .orange).frame(width: 4, height: 4)
                    Text(source.harness.title)
                    if source.scope == .otherFolder { Text("· \(source.groupTitle)") }
                    if source.example { Text("· Example") }
                }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .contentShape(.rect).help(source.location)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(filename), \(source.harness.title), \(source.scope.title), \(source.groupTitle)")
    }
}

#Preview { MemoryViewPreview() }
