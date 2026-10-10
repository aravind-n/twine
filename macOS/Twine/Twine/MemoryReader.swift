import AppKit
import SwiftUI

struct MemoryReader: View {
    @Bindable var model: MemoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let source = model.selected {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(source.title).font(.headline).textSelection(.enabled)
                        Spacer()
                        Label("Read-only", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(source.harness.title) · \(source.scope.title) · \(source.kind.title)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(source.shortPath).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if source.example {
                        Text("Emulated source · isolated fixture").font(.caption).foregroundStyle(.orange)
                    }
                    if let association = source.association {
                        Text(association).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    HStack {
                        Text(source.format.uppercased())
                        if let modified = source.modifiedAt {
                            Text(Date(timeIntervalSince1970: TimeInterval(modified)), format: .dateTime)
                        }
                    }.font(.caption2).foregroundStyle(.tertiary)
                }.padding(16)
                Divider()
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityIdentifier("memoryReader")
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
                MemoryTextView(text: text)
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
