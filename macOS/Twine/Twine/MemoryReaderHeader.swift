import SwiftUI

struct MemoryReaderHeader: View {
    let source: CoreMemorySource
    let lineCount: Int
    @Binding var display: MemoryDisplay
    let canEdit: Bool
    let edit: () -> Void
    @State private var showsInfo = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                filename.frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                controls.fixedSize()
            }.frame(height: 44)
            VStack(alignment: .leading, spacing: 6) {
                filename
                controls
            }.padding(.vertical, 9)
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .contain).accessibilityIdentifier("memoryReaderToolbar")
        .onChange(of: source.id) { showsInfo = false }
    }

    private var filename: some View {
        Text(source.title).font(.system(size: 12, weight: .semibold))
            .lineLimit(1).truncationMode(.middle).help(source.title)
            .accessibilityIdentifier("memoryFilename")
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if source.isMarkdown {
                Picker("Memory display", selection: $display) {
                    ForEach(MemoryDisplay.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                .accessibilityIdentifier("memoryDisplayMode")
            }
            if canEdit {
                Button("Edit", systemImage: "pencil", action: edit)
                    .accessibilityLabel("Edit Markdown").accessibilityIdentifier("editMemoryMarkdown")
            }
            Button("Source information", systemImage: "info.circle") { showsInfo.toggle() }
                .labelStyle(.iconOnly).buttonStyle(.plain).help("Source information")
                .accessibilityIdentifier("memorySourceInfo")
                .popover(isPresented: $showsInfo) { sourceInfo }
        }.controlSize(.small)
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

#Preview { MemoryViewPreview() }
