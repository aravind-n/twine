import SwiftUI

struct MemorySourceInfo: View {
    let source: CoreMemorySource
    let lineCount: Int
    let canEdit: Bool
    @State private var showsInfo = false

    var body: some View {
        Button("Source information", systemImage: "info.circle") { showsInfo.toggle() }
            .labelStyle(.iconOnly).buttonStyle(.plain).help("Source information")
            .accessibilityIdentifier("memorySourceInfo")
            .popover(isPresented: $showsInfo) { sourceInfo }
            .onChange(of: source.id) { showsInfo = false }
    }

    private var sourceInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(source.title).font(.headline)
            Text("\(source.harness.title) · \(source.scope.title)").foregroundStyle(.secondary)
            Text(source.shortPath).font(.caption.monospaced()).textSelection(.enabled)
            Divider()
            Text(source.association ?? provenance)
            Text("\(source.kind.title) · \(source.format.uppercased()) · \(lineCount) lines")
            if let modified = source.modifiedAt {
                Text(Date(timeIntervalSince1970: TimeInterval(modified)), format: .dateTime)
            }
            Label(source.example ? "Example source" : "Stored on this Mac", systemImage: "internaldrive")
            if !canEdit { Label("Read-only source", systemImage: "lock") }
        }.font(.caption).padding(16).frame(width: 320, alignment: .leading)
    }

    private var provenance: String {
        switch source.scope {
        case .global: "A local source available across workspaces."
        case .folder: "Associated with this workspace. Nested instructions apply to their own subtree."
        case .otherFolder: "Stored locally, but not associated with this workspace."
        }
    }
}
