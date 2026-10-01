import AppKit
import SwiftUI

struct FileLineRequest: Equatable {
    let id = UUID()
    let line: Int
}

struct FileTextView: NSViewRepresentable {
    @Binding var text: String
    let loadID: UUID
    let isEditable: Bool
    let isVisible: Bool
    let lineRequest: FileLineRequest?

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> FileContentHost<NSScrollView> {
        let scroll = FileEditingTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else {
            return FileContentHost(content: scroll, responder: scroll)
        }
        view.isEditable = isEditable
        view.isSelectable = true
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 18, height: 18)
        scroll.verticalRulerView = FileLineNumberRuler(textView: view, scrollView: scroll)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        view.setAccessibilityIdentifier("fileText")
        view.setAccessibilityLabel("File contents")
        return FileContentHost(content: scroll, responder: view)
    }

    func updateNSView(_ host: FileContentHost<NSScrollView>, context: Context) {
        let scroll = host.content
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        view.isEditable = isEditable
        host.setVisible(isVisible)
        if context.coordinator.loadID != loadID {
            view.undoManager?.removeAllActions()
            context.coordinator.loadID = loadID
        }
        if view.string != text {
            let selected = view.selectedRange()
            let origin = scroll.contentView.bounds.origin
            view.string = text
            (scroll.verticalRulerView as? FileLineNumberRuler)?.refresh()
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
                host.requestKeyboardFocus()
            }
        }
    }

    static func dismantleNSView(_ host: FileContentHost<NSScrollView>, coordinator: Coordinator) {
        guard let view = host.content.documentView as? NSTextView else { return }
        view.undoManager?.removeAllActions()
        view.delegate = nil
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

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let fileUndoManager = UndoManager()
        var text: Binding<String>
        var loadID: UUID?
        var lastRequest: UUID?

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
            (view.enclosingScrollView?.verticalRulerView as? FileLineNumberRuler)?.refresh()
        }

        func undoManager(for view: NSTextView) -> UndoManager? { fileUndoManager }
    }
}

/// Native text layout can finish after the scroll view's ruler has drawn.
private final class FileEditingTextView: NSTextView {
    override func layout() {
        super.layout()
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }
}
