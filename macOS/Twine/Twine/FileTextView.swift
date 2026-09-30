import AppKit
import SwiftUI

struct FileLineRequest: Equatable {
    let id = UUID()
    let line: Int
}

struct FileTextView: NSViewRepresentable {
    let text: String
    let lineRequest: FileLineRequest?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 18, height: 18)
        view.setAccessibilityIdentifier("fileText")
        view.setAccessibilityLabel("Read-only file contents")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text {
            let selected = view.selectedRange()
            let origin = scroll.contentView.bounds.origin
            view.string = text
            let length = (text as NSString).length
            let location = min(selected.location, length)
            view.setSelectedRange(NSRange(location: location, length: min(selected.length, length - location)))
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if let request = lineRequest, context.coordinator.lastRequest != request.id {
            context.coordinator.lastRequest = request.id
            if let range = Self.lineRange(in: text, line: request.line) {
                view.setSelectedRange(range)
                view.scrollRangeToVisible(range)
                view.window?.makeFirstResponder(view)
            }
        }
    }

    /// NSString offsets match NSTextView's UTF-16 selections, including CRLF and emoji.
    static func lineRange(in text: String, line: Int) -> NSRange? {
        guard line > 0 else { return nil }
        let source = text as NSString
        var start = 0
        for _ in 1..<line {
            guard start < source.length else { return nil }
            var end = 0
            var contentsEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            guard end > contentsEnd else { return nil }
            start = end
        }
        var end = start
        source.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: start, length: 0))
        return NSRange(location: start, length: end - start)
    }

    final class Coordinator {
        var lastRequest: UUID?
    }
}
