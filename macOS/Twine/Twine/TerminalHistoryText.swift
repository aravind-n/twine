import AppKit
import SwiftUI

/// Snapshot rows keep their original wrapping. Resizing the window only changes the viewport.
struct TerminalHistoryText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.autoresizingMask = []
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = view.maxSize
        view.textContainerInset = NSSize(width: Spacing.terminalContent, height: Spacing.terminalContent)
        view.font = .terminal
        view.setAccessibilityIdentifier("terminalHistoryText")
        view.setAccessibilityLabel("Historical terminal output, read only")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        view.backgroundColor = .terminalBackground
        view.textColor = .terminalText
        if view.string != text {
            view.string = text
            view.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0))
        }
    }
}

#Preview { TerminalHistoryText(text: "Historical terminal output\n") }
