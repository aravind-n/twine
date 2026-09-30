import AppKit
import Testing

@testable import Twine

@MainActor
struct TerminalHistoryTextTests {
    @Test func viewportShowsOutputInsteadOfTrailingBlankTerminalRows() throws {
        let scroll = TerminalHistoryText.makeScrollView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 160)
        let window = NSWindow(
            contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        let text =
            "command\nFINAL_HISTORY\n" + String(repeating: "long historical row ", count: 12)
            + String(repeating: "\n", count: 40)
        TerminalHistoryText.show(text, in: scroll)
        scroll.layoutSubtreeIfNeeded()
        let view = try #require(scroll.documentView as? NSTextView)
        let layout = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        let range = (text as NSString).range(of: "FINAL_HISTORY")
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let output = layout.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        #expect(view.visibleRect.intersects(output))
        #expect(scroll.contentView.bounds.minX == 0)
        #expect(view.string == text)
    }
}
