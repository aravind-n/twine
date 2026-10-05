import AppKit
import TwineSyntax

/// Supplies color-only attributes to TextKit 2, including fragments created after scrolling.
final class FileSyntaxRenderer: NSObject {
    var isVisible = false
    private weak var textView: NSTextView?
    private var tokens: [SyntaxToken] = []
    private var paintedFragments: Set<ObjectIdentifier> = []
    private var viewportTask: Task<Void, Never>?

    deinit { NotificationCenter.default.removeObserver(self) }

    func attach(to view: NSTextView) {
        textView = view
        if let clip = view.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: clip)
        }
        view.textLayoutManager?.renderingAttributesValidator = { [weak self] layout, fragment in
            self?.paint(fragment, in: layout)
        }
    }

    func detach() {
        NotificationCenter.default.removeObserver(
            self, name: NSView.boundsDidChangeNotification, object: textView?.enclosingScrollView?.contentView)
        viewportTask?.cancel()
        viewportTask = nil
        textView?.textLayoutManager?.renderingAttributesValidator = nil
        textView = nil
        tokens = []
        paintedFragments.removeAll()
    }

    func replaceTokens(_ tokens: [SyntaxToken]) {
        self.tokens = tokens
        invalidate()
    }

    func invalidate() {
        paintedFragments.removeAll()
        guard let view = textView, let layout = view.textLayoutManager,
            let content = layout.textContentManager
        else { return }
        layout.invalidateRenderingAttributes(for: content.documentRange)
        refreshViewport()
    }

    func refreshViewport() {
        guard isVisible, let view = textView, !view.hasMarkedText(),
            let layout = view.textLayoutManager
        else { return }
        let start = layout.textViewportLayoutController.viewportRange?.location
        let visible = view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
        var painted = false
        // Do not force offscreen layout. Retained fragments also need repainting after async parsing.
        layout.enumerateTextLayoutFragments(from: start, options: []) { fragment in
            if fragment.layoutFragmentFrame.minY > visible.maxY { return false }
            guard fragment.layoutFragmentFrame.maxY >= visible.minY,
                fragment.state == .layoutAvailable,
                !self.paintedFragments.contains(ObjectIdentifier(fragment))
            else { return true }
            self.paint(fragment, in: layout)
            painted = true
            return true
        }
        if painted { markForDisplay(view) }
    }

    @objc private func viewportChanged() {
        viewportTask?.cancel()
        // Clip bounds can change before TextKit updates the viewport range.
        viewportTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.refreshViewport()
        }
    }

    private func paint(_ fragment: NSTextLayoutFragment, in layout: NSTextLayoutManager) {
        guard isVisible, let view = textView, !view.hasMarkedText(),
            let content = layout.textContentManager
        else { return }
        let range = fragment.rangeInElement
        let start = content.offset(from: content.documentRange.location, to: range.location)
        let length = content.offset(from: range.location, to: range.endLocation)
        guard start >= 0, length >= 0 else { return }
        layout.removeRenderingAttribute(.foregroundColor, for: range)
        paintedFragments.insert(ObjectIdentifier(fragment))
        let end = start + length
        let first = firstToken(endingAfter: start)
        var last = first
        while last < tokens.count, tokens[last].range.location < end {
            last += 1
            // A minified line must not monopolize the main actor with thousands of style runs.
            if last - first > 2_000 { return }
        }
        for token in tokens[first..<last] {
            let clipped = NSIntersectionRange(token.range, NSRange(location: start, length: length))
            guard clipped.length > 0,
                let lower = content.location(range.location, offsetBy: clipped.location - start),
                let upper = content.location(lower, offsetBy: clipped.length),
                let textRange = NSTextRange(location: lower, end: upper)
            else { continue }
            layout.addRenderingAttribute(.foregroundColor, value: color(for: token.kind), for: textRange)
        }
    }

    private func firstToken(endingAfter offset: Int) -> Int {
        var lower = 0
        var upper = tokens.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if NSMaxRange(tokens[middle].range) <= offset { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    private func color(for kind: SyntaxTokenKind) -> NSColor {
        switch kind {
        case .keyword: .systemPurple
        case .string: .systemRed
        case .comment: .secondaryLabelColor
        case .number: .systemBlue
        case .type: .systemTeal
        case .function: .systemIndigo
        case .property: .systemBrown
        case .operator, .punctuation, .variable: .textColor
        }
    }

    private func markForDisplay(_ view: NSView) {
        view.needsDisplay = true
        for child in view.subviews { markForDisplay(child) }
    }
}
