import AppKit
import Testing
import TwineSyntax

@testable import Twine

@Suite(.serialized)
@MainActor
struct FileSyntaxRenderingTests {
    @Test func arrivingTokensRepaintExistingFragmentsWithoutChangingEditingState() throws {
        let original = "let greeting = \"🌲 café\"\r\nlet count = 42\r\n"
        let fixture = try SyntaxTextFixture(source: original)
        defer { fixture.window.close() }
        let number = (original as NSString).range(of: "42")
        fixture.replace(number, with: "43")
        let source = fixture.view.string
        let selection = (source as NSString).range(of: "🌲 café")
        fixture.view.setSelectedRange(selection)
        let storage = fixture.view.attributedString()
        fixture.layoutViewport()
        #expect(fixture.undo.canUndo)

        let renderer = FileSyntaxRenderer()
        renderer.isVisible = true
        renderer.attach(to: fixture.view)
        defer { renderer.detach() }
        // The first viewport already exists before the asynchronous result arrives.
        renderer.replaceTokens([
            SyntaxToken(range: NSRange(location: 0, length: 3), kind: .keyword),
            SyntaxToken(range: number, kind: .number),
        ])
        #expect(try fixture.color(at: 0) == .systemPurple)
        #expect(try fixture.color(at: number.location) == .systemBlue)
        #expect(fixture.view.attributedString().isEqual(to: storage))
        #expect(fixture.view.string == source)
        #expect(fixture.view.selectedRange() == selection)
        #expect(fixture.undo.canUndo)
        #expect(!fixture.undo.canRedo)
        #expect(try fixture.renderedSpans().allSatisfy { Set($0.attributes.keys) == [.foregroundColor] })

        fixture.undo.undo()
        #expect(fixture.view.string == original)
        #expect(fixture.undo.canRedo)
    }

    @Test func replacingAndRemovingTokensClearEarlierRenderingColors() throws {
        let fixture = try SyntaxTextFixture(source: "let count = 42\n")
        defer { fixture.window.close() }
        let renderer = FileSyntaxRenderer()
        renderer.isVisible = true
        renderer.attach(to: fixture.view)
        defer { renderer.detach() }
        renderer.replaceTokens([SyntaxToken(range: NSRange(location: 0, length: 3), kind: .keyword)])
        #expect(try fixture.color(at: 0) == .systemPurple)
        renderer.replaceTokens([SyntaxToken(range: NSRange(location: 12, length: 2), kind: .number)])
        #expect(try fixture.color(at: 0) == nil)
        #expect(try fixture.color(at: 12) == .systemBlue)
        renderer.replaceTokens([])
        #expect(try fixture.renderedSpans().isEmpty)
        #expect(fixture.view.string == "let count = 42\n")
        #expect(!fixture.undo.canUndo)
    }

    @Test func parserResultsColorNativeLayoutWithoutAddingStorageAttributes() async throws {
        let source = "// 🌲 café\r\nlet value = 42\r\n"
        let fixture = try SyntaxTextFixture(source: source)
        defer { fixture.window.close() }
        let storage = fixture.view.attributedString()
        let highlighter = FileSyntaxHighlighter()
        highlighter.attach(to: fixture.view)
        defer { highlighter.detach() }
        highlighter.update(language: .swift, loadID: UUID(), isVisible: true)
        let pending = try #require(highlighter.pendingTask)
        await pending.value
        let keyword = (source as NSString).range(of: "let")
        let number = (source as NSString).range(of: "42")
        #expect(try fixture.color(at: 0) == .secondaryLabelColor)
        #expect(try fixture.color(at: keyword.location) == .systemPurple)
        #expect(try fixture.color(at: number.location) == .systemBlue)
        #expect(fixture.view.attributedString().isEqual(to: storage))
        #expect(!fixture.undo.canUndo)
    }

    @Test func disablingLanguageRejectsPendingResultsAndClearsAppliedColors() async throws {
        let fixture = try SyntaxTextFixture(source: "let count = 42\n")
        defer { fixture.window.close() }
        let highlighter = FileSyntaxHighlighter()
        highlighter.attach(to: fixture.view)
        defer { highlighter.detach() }
        let loadID = UUID()
        highlighter.update(language: .swift, loadID: loadID, isVisible: true)
        let stale = try #require(highlighter.pendingTask)
        highlighter.update(language: nil, loadID: loadID, isVisible: true)
        await stale.value
        #expect(highlighter.pendingTask == nil)
        #expect(try fixture.renderedSpans().isEmpty)

        highlighter.update(language: .swift, loadID: loadID, isVisible: true)
        await highlighter.pendingTask?.value
        #expect(try fixture.color(at: 0) == .systemPurple)
        highlighter.update(language: nil, loadID: loadID, isVisible: true)
        #expect(try fixture.renderedSpans().isEmpty)
    }

    @Test func hidingCancelsPendingWorkAndShowingRepaintsTheDocument() async throws {
        let fixture = try SyntaxTextFixture(source: "let count = 42\n")
        defer { fixture.window.close() }
        let highlighter = FileSyntaxHighlighter()
        highlighter.attach(to: fixture.view)
        defer { highlighter.detach() }
        let loadID = UUID()
        highlighter.update(language: .swift, loadID: loadID, isVisible: true)
        let stale = try #require(highlighter.pendingTask)
        highlighter.update(language: .swift, loadID: loadID, isVisible: false)
        await stale.value
        #expect(highlighter.pendingTask == nil)
        #expect(try fixture.renderedSpans().isEmpty)
        highlighter.update(language: .swift, loadID: loadID, isVisible: true)
        let visible = try #require(highlighter.pendingTask)
        await visible.value
        #expect(try fixture.color(at: 0) == .systemPurple)
        #expect(fixture.view.string == "let count = 42\n")
    }

    @Test func reloadingWhileWorkIsPendingOnlyColorsTheNewDocument() async throws {
        let fixture = try SyntaxTextFixture(source: "let count = 42\n")
        defer { fixture.window.close() }
        let highlighter = FileSyntaxHighlighter()
        highlighter.attach(to: fixture.view)
        defer { highlighter.detach() }
        highlighter.update(language: .swift, loadID: UUID(), isVisible: true)
        let stale = try #require(highlighter.pendingTask)
        let replacement = "// Replaced source with 🌲 and no number\r\n"
        fixture.view.string = replacement
        fixture.layoutViewport()
        highlighter.update(language: .swift, loadID: UUID(), isVisible: true)
        let current = try #require(highlighter.pendingTask)
        await stale.value
        await current.value
        #expect(try fixture.color(at: 0) == .secondaryLabelColor)
        #expect(try fixture.color(at: 12) == .secondaryLabelColor)
        #expect(fixture.view.string == replacement)
        #expect(!fixture.undo.canUndo)
    }

    @Test func editsInvalidateOldTokensAndRepaintTheNewSyntax() async throws {
        let fixture = try SyntaxTextFixture(source: "let value = 42\n")
        defer { fixture.window.close() }
        let highlighter = FileSyntaxHighlighter()
        highlighter.attach(to: fixture.view)
        defer { highlighter.detach() }
        highlighter.update(language: .swift, loadID: UUID(), isVisible: true)
        await highlighter.pendingTask?.value
        #expect(try fixture.color(at: 12) == .systemBlue)
        fixture.replace(NSRange(location: 12, length: 2), with: "\"🌲\"")
        highlighter.textDidChange()
        #expect(try fixture.renderedSpans().isEmpty)
        fixture.layoutViewport()
        await highlighter.pendingTask?.value
        #expect(try fixture.color(at: 12) == .systemRed)
        #expect(fixture.view.string == "let value = \"🌲\"\n")
        fixture.undo.undo()
        #expect(fixture.view.string == "let value = 42\n")
    }

    @Test func scrollingPaintsNewlyVisibleFragments() async throws {
        let rows = (0..<150).map { "let number\($0) = \($0)\n" }
        let source = rows.joined()
        let fixture = try SyntaxTextFixture(source: source)
        defer { fixture.window.close() }
        let last = (source as NSString).range(of: "let number149")
        // Retain lower fragments laid out before tokens arrive, then accept the result at the top.
        fixture.view.scrollRangeToVisible(last)
        fixture.layoutViewport()
        fixture.view.scrollRangeToVisible(NSRange(location: 0, length: 3))
        fixture.layoutViewport()
        let highlighter = FileSyntaxHighlighter()
        highlighter.attach(to: fixture.view)
        fixture.view.syntax = highlighter
        defer { highlighter.detach() }
        highlighter.update(language: .swift, loadID: UUID(), isVisible: true)
        await highlighter.pendingTask?.value
        #expect(try fixture.color(at: 0) == .systemPurple)
        #expect(try fixture.color(at: last.location) == nil)
        fixture.view.scrollRangeToVisible(last)
        fixture.layoutViewport()
        // Production text-view layout and clip-bounds observation must request the repaint.
        try await waitUntil({ (try? fixture.color(at: last.location)) == .systemPurple }, timeout: .seconds(2))
        #expect(fixture.scroll.contentView.bounds.minY > 0)
        #expect(try fixture.color(at: last.location) == .systemPurple)
        let number = (source as NSString).range(of: "149", options: .backwards)
        #expect(try fixture.color(at: number.location) == .systemBlue)
    }

    @Test func markedTextDefersParsingAndUnmarkingHighlightsTheCommittedComposition() async throws {
        let fixture = try SyntaxTextFixture(source: "let name = \"\"\n")
        defer { fixture.window.close() }
        let highlighter = FileSyntaxHighlighter()
        highlighter.attach(to: fixture.view)
        fixture.view.syntax = highlighter
        defer { highlighter.detach() }
        fixture.undo.beginUndoGrouping()
        fixture.view.setMarkedText(
            "名🌲", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: 12, length: 0))
        fixture.undo.endUndoGrouping()
        #expect(fixture.view.hasMarkedText())
        let marked = fixture.view.markedRange()
        let selection = fixture.view.selectedRange()
        let storage = fixture.view.attributedString()
        highlighter.update(language: .swift, loadID: UUID(), isVisible: true)
        #expect(highlighter.pendingTask == nil)
        #expect(try fixture.renderedSpans().isEmpty)
        #expect(fixture.view.hasMarkedText())
        #expect(fixture.view.markedRange() == marked)
        #expect(fixture.view.selectedRange() == selection)
        #expect(fixture.view.attributedString().isEqual(to: storage))

        // FileEditingTextView must schedule the deferred work when the input method commits.
        fixture.view.unmarkText()
        #expect(!fixture.view.hasMarkedText())
        let committedSelection = fixture.view.selectedRange()
        fixture.layoutViewport()
        let pending = try #require(highlighter.pendingTask)
        await pending.value
        #expect(try fixture.color(at: 0) == .systemPurple)
        #expect(try fixture.color(at: 12) == .systemRed)
        #expect(fixture.view.string == "let name = \"名🌲\"\n")
        #expect(fixture.view.selectedRange() == committedSelection)
    }
}

@MainActor
private final class SyntaxTextFixture: NSObject, NSTextViewDelegate {
    let window: NSWindow
    let scroll: NSScrollView
    let view: FileEditingTextView
    let layout: NSTextLayoutManager
    let undo = UndoManager()

    init(source: String) throws {
        scroll = FileEditingTextView.scrollableTextView()
        view = try #require(scroll.documentView as? FileEditingTextView)
        layout = try #require(view.textLayoutManager)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        view.isRichText = false
        view.allowsUndo = true
        view.isEditable = true
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = .textColor
        view.textContainerInset = NSSize(width: 18, height: 18)
        view.delegate = self
        undo.groupsByEvent = false
        window.contentView = scroll
        view.string = source
        layoutViewport()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    func replace(_ range: NSRange, with replacement: String) {
        undo.beginUndoGrouping()
        view.insertText(replacement, replacementRange: range)
        view.breakUndoCoalescing()
        undo.endUndoGrouping()
    }

    func layoutViewport() {
        scroll.layoutSubtreeIfNeeded()
        layout.textViewportLayoutController.layoutViewport()
    }

    func color(at offset: Int) throws -> NSColor? {
        try renderedSpans().first { NSLocationInRange(offset, $0.range) }?.attributes[.foregroundColor] as? NSColor
    }

    func renderedSpans() throws -> [RenderedSyntaxSpan] {
        let content = try #require(layout.textContentManager)
        var result: [RenderedSyntaxSpan] = []
        // Enumeration reads stored rendering attributes and does not invoke their validator.
        layout.enumerateRenderingAttributes(from: content.documentRange.location, reverse: false) { _, attrs, range in
            let start = content.offset(from: content.documentRange.location, to: range.location)
            let length = content.offset(from: range.location, to: range.endLocation)
            result.append(RenderedSyntaxSpan(range: NSRange(location: start, length: length), attributes: attrs))
            return true
        }
        return result
    }
}

private struct RenderedSyntaxSpan {
    let range: NSRange
    let attributes: [NSAttributedString.Key: Any]
}
