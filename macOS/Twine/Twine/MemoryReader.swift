import AppKit
import SwiftUI

struct MemoryReader: View {
    @Environment(FileTabsModel.self) private var tabs
    @Bindable var model: MemoryModel
    var folder: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let source = model.selected {
                MemoryReaderHeader(
                    source: source, lineCount: model.contents?.text?.components(separatedBy: "\n").count ?? 0,
                    display: $model.display, canEdit: model.editableFile != nil,
                    edit: {
                        if let file = model.editableFile {
                            tabs.openMemory(file, request: model.request(folder: folder, sourceID: source.id))
                        }
                    })
                Divider()
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let source = model.selected {
                Divider()
                DisclosureGroup("Source details") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(source.location).textSelection(.enabled)
                        Text("\(source.kind.title) · \(source.format.uppercased())")
                        if let modified = source.modifiedAt {
                            Text(Date(timeIntervalSince1970: TimeInterval(modified)), format: .dateTime)
                        }
                    }.font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 9)
            }
        }.background(MemoryPalette.document)
            .accessibilityElement(children: .contain).accessibilityIdentifier("memoryReader")
    }

    @ViewBuilder private var content: some View {
        switch model.readState {
        case .idle:
            ContentUnavailableView("Select a Source", systemImage: "doc.text.magnifyingglass")
        case .loading:
            ProgressView("Reading local source…")
        case .failed(let message):
            ContentUnavailableView(
                "Couldn't Read Source", systemImage: "exclamationmark.triangle",
                description: Text(message))
        case .available:
            if let text = model.contents?.text {
                if model.selected?.isMarkdown == true, model.display == .rendered, let read = model.contents {
                    // Database records get a virtual document base; only real files offer editing.
                    let file =
                        read.file
                        ?? FilePreview(
                            path: read.source.location, status: .text, text: text, message: nil,
                            version: FileVersion(fingerprint: model.generation.uuidString, utf8BOM: false))
                    HTMLPreview(
                        file: file, folder: URL(filePath: file.path).deletingLastPathComponent().path,
                        navigationURL: model.navigationURL, isVisible: true,
                        openFile: model.openLink, format: .markdown, localResourcesOnly: true, markdownStyle: .memory
                    )
                    .id(file.path)
                } else {
                    MemoryTextView(text: text)
                }
            } else {
                ContentUnavailableView(
                    "Source Unavailable", systemImage: "doc.badge.ellipsis",
                    description: Text(model.contents?.message ?? "Refresh the source list to try again."))
            }
        }
    }
}

struct MemoryTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.allowsUndo = false
            view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            view.textColor = .textColor
            view.backgroundColor = .textBackgroundColor
            view.textContainerInset = NSSize(width: 18, height: 18)
            view.setAccessibilityIdentifier("memoryText")
            view.setAccessibilityLabel("Read-only memory contents")
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}

#Preview { MemoryViewPreview() }
