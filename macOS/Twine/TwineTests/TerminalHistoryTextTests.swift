import AppKit
import Testing

@testable import Twine

@MainActor
struct TerminalHistoryTextTests {
    @Test func commandViewportStartsAtItsFirstOutputRow() throws {
        let scroll = TerminalHistoryText.makeScrollView()
        let prefix = String(repeating: "previous output\n", count: 40)
        let text = prefix + "FIRST_COMMAND_OUTPUT\n" + String(repeating: "command output\n", count: 80)
        TerminalHistoryText.show(
            text, outputStartRange: NSRange(location: (prefix as NSString).length, length: 1), in: scroll)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 160), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        let view = try #require(scroll.documentView as? NSTextView)
        let layout = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        let glyphs = layout.glyphRange(
            forCharacterRange: (text as NSString).range(of: "FIRST_COMMAND_OUTPUT"), actualCharacterRange: nil)
        let output = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(
            dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        #expect(view.visibleRect.intersects(output))
        #expect(abs(scroll.contentView.bounds.minY - (output.minY - view.textContainerInset.height)) < 1)
    }

    @Test func viewportShowsOutputInsteadOfTrailingBlankTerminalRows() throws {
        let scroll = TerminalHistoryText.makeScrollView()
        let text =
            "command\nFINAL_HISTORY\n" + String(repeating: "long historical row ", count: 12)
            + String(repeating: "\n", count: 40)
        // SwiftUI updates text while the newly created view still has a zero-sized frame.
        TerminalHistoryText.show(text, in: scroll)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
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
