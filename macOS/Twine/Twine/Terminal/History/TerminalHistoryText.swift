import AppKit
import SwiftUI

/// Snapshot rows keep their original wrapping. Resizing the window only changes the viewport.
struct TerminalHistoryText: NSViewRepresentable {
    let text: String
    var outputStartRange: NSRange?
    var font = NSFont.terminal
    var minimap: TerminalMinimapState?
    var markerRows: [UInt64: Int] = [:]
    var palette: TerminalPalette?

    func makeNSView(context: Context) -> TerminalHistoryScrollView {
        let scroll = Self.makeScrollView(font: font)
        scroll.minimapState = minimap
        minimap?.historyView = scroll
        if minimap != nil { scroll.hasVerticalScroller = false }
        return scroll
    }

    static func makeScrollView(font: NSFont = .terminal) -> TerminalHistoryScrollView {
        let source = NSTextView.scrollableTextView()
        let scroll = TerminalHistoryScrollView()
        scroll.documentView = source.documentView
        scroll.hasVerticalScroller = true
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
        view.font = font
        view.setAccessibilityIdentifier("terminalHistoryText")
        view.setAccessibilityLabel("Historical terminal output, read only")
        return scroll
    }

    func updateNSView(_ scroll: TerminalHistoryScrollView, context: Context) {
        Self.show(text, outputStartRange: outputStartRange, in: scroll, font: font, palette: palette)
        minimap?.showHistory(text: text, rows: markerRows)
    }

    static func show(
        _ text: String, outputStartRange: NSRange? = nil, in scroll: TerminalHistoryScrollView,
        font: NSFont = .terminal,
        palette: TerminalPalette? = nil
    ) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.font != font { view.font = font }
        let palette = palette ?? TerminalPalette.resolved(for: scroll.effectiveAppearance)
        scroll.backgroundColor = palette.background
        view.backgroundColor = palette.background
        view.textColor = palette.text
        view.selectedTextAttributes = [.backgroundColor: palette.selection, .foregroundColor: palette.text]
        if view.string != text || scroll.outputStartRange != outputStartRange {
            view.string = text
            scroll.outputStartRange = outputStartRange
            scroll.pendingOutput =
                outputStartRange
                ?? (text as NSString).rangeOfCharacter(
                    from: .whitespacesAndNewlines.inverted, options: .backwards)
            scroll.needsLayout = true
        }
    }
}

/// SwiftUI supplies the text before the viewport has a size. Position it once layout has real bounds.
final class TerminalHistoryScrollView: NSScrollView {
    weak var minimapState: TerminalMinimapState?
    var pendingOutput: NSRange?
    var outputStartRange: NSRange?

    override func layout() {
        super.layout()
        defer { minimapState?.scheduleRefresh() }
        guard let range = pendingOutput, contentView.bounds.height > 0,
            let view = documentView as? NSTextView,
            let layout = view.layoutManager, let container = view.textContainer
        else { return }
        pendingOutput = nil
        guard range.location != NSNotFound else { return }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let output = layout.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let targetY =
            outputStartRange == nil
            ? output.maxY + view.textContainerInset.height - contentView.bounds.height
            : output.minY - view.textContainerInset.height
        let origin = NSPoint(x: 0, y: max(0, targetY))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        minimapState?.scheduleRefresh()
    }
}

#Preview { TerminalHistoryText(text: "Historical terminal output\n") }
