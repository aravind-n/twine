import SwiftUI

struct MemoryReaderHeader: View {
    let source: CoreMemorySource
    let lineCount: Int
    @Binding var display: MemoryDisplay
    let canEdit: Bool
    let edit: () -> Void

    private var provenance: String {
        if let association = source.association { return association }
        switch source.scope {
        case .global: return "A local source available across folders."
        case .folder: return "Associated with this folder. Nested instructions apply to their own subtree."
        case .otherFolder: return "Stored locally, but not associated with the open folder."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                MemoryBadge(source.harness.title, tint: source.harness == .codex ? .blue : .orange)
                MemoryBadge(source.scope.title)
                MemoryBadge(source.example ? "Example" : "On this Mac", tint: source.example ? .orange : .green)
            }
            Text(source.title).font(.system(size: 16, weight: .semibold)).textSelection(.enabled)
            Text(source.shortPath).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                .help(source.location)
            Text(provenance).font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 9)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
            ViewThatFits(in: .horizontal) {
                HStack {
                    displayControl
                    Spacer()
                    editControl
                }
                VStack(alignment: .leading, spacing: 8) {
                    displayControl
                    editControl
                }
            }
            .padding(.top, 4)
        }.padding(18)
    }

    @ViewBuilder private var displayControl: some View {
        if source.isMarkdown {
            Picker("Memory display", selection: $display) {
                ForEach(MemoryDisplay.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 180)
            .accessibilityIdentifier("memoryDisplayMode")
        } else {
            Text("\(source.kind.title) · \(lineCount) lines").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var editControl: some View {
        if canEdit {
            Button("Edit Markdown", systemImage: "pencil", action: edit)
                .controlSize(.small).accessibilityIdentifier("editMemoryMarkdown")
        } else {
            Label("Read-only", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
        }
    }
}

#Preview { MemoryViewPreview() }
