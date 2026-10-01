import AppKit

/// UTF-16 offsets match the native text system. Wrapped continuations do not start a new line.
struct FileLineIndex {
    let starts: [Int]

    init(_ text: String) {
        let source = text as NSString
        var starts = [0]
        var offset = 0
        while offset < source.length {
            var end = 0
            var contentsEnd = 0
            source.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
            guard end > offset else { break }
            if end > contentsEnd { starts.append(end) }
            offset = end
        }
        self.starts = starts
    }

    func number(startingAt offset: Int) -> Int? {
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if starts[middle] < offset { lower = middle + 1 } else { upper = middle }
        }
        guard lower < starts.count, starts[lower] == offset else { return nil }
        return lower + 1
    }
}

/// Draw only the visible TextKit 2 line fragments, outside the editable document.
final class FileLineNumberRuler: NSRulerView {
    private var lines = FileLineIndex("")
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Line numbers")
        setAccessibilityIdentifier("fileLineNumbers")
        refresh()
    }

    required init(coder: NSCoder) { super.init(coder: coder) }

    deinit { NotificationCenter.default.removeObserver(self) }

    func refresh() {
        guard let view = clientView as? NSTextView else { return }
        lines = FileLineIndex(view.string)
        let width = (String(lines.starts.count) as NSString).size(withAttributes: [.font: numberFont]).width
        ruleThickness = max(36, ceil(width) + 18)
        setAccessibilityValue("\(lines.starts.count) lines")
        needsDisplay = true
    }

    @objc private func viewportChanged() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.textBackgroundColor.setFill()
        bounds.intersection(rect).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        guard let view = clientView as? NSTextView,
            let layout = view.textLayoutManager, let content = layout.textContentManager
        else { return }
        let origin = view.textContainerOrigin
        if view.string.isEmpty {
            drawNumber(1, baseline: convert(NSPoint(x: 0, y: origin.y + (view.font?.ascender ?? 13)), from: view).y)
            return
        }
        let visible = view.visibleRect
        let start = layout.textViewportLayoutController.viewportRange?.location ?? content.documentRange.location
        layout.enumerateTextLayoutFragments(
            from: start, options: [.ensuresLayout, .ensuresExtraLineFragment]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + origin.y > visible.maxY { return false }
            if frame.maxY + origin.y < visible.minY { return true }
            let elementStart = fragment.textElement?.elementRange?.location ?? fragment.rangeInElement.location
            let offset = content.offset(from: content.documentRange.location, to: elementStart)
            for line in fragment.textLineFragments {
                guard let number = self.lines.number(startingAt: offset + line.characterRange.location) else {
                    continue
                }
                let baseline = origin.y + frame.minY + line.typographicBounds.minY + line.glyphOrigin.y
                self.drawNumber(number, baseline: self.convert(NSPoint(x: 0, y: baseline), from: view).y)
            }
            return true
        }
    }

    private func drawNumber(_ number: Int, baseline: CGFloat) {
        let label = String(number) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont, .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(x: bounds.maxX - size.width - 8, y: baseline - numberFont.ascender), withAttributes: attributes)
    }
}
