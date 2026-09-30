import AppKit
import MetalKit
import SwiftTerm
import Testing

@testable import Twine

struct MetalTerminalViewTests {
    @Test @MainActor func fontChangesResizeTheGridAndUnchangedFontsPreserveSelection() throws {
        let terminal = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let small = try #require(NSFont(name: "Menlo-Regular", size: 13))
        let large = try #require(NSFont(name: "Menlo-Regular", size: 26))
        terminal.applyTwineFont(small)
        let columns = terminal.getTerminal().cols
        let rows = terminal.getTerminal().rows
        terminal.applyTwineFont(large)
        #expect(terminal.font == large)
        #expect(terminal.getTerminal().cols < columns)
        #expect(terminal.getTerminal().rows < rows)

        terminal.feed(byteArray: Array("selected output".utf8)[...])
        terminal.selectAll(nil)
        #expect(terminal.selection.active)
        terminal.applyTwineFont(large)
        #expect(terminal.selection.active)
    }

    @Test @MainActor func hidingDefersUntilTheUpdateReturnsAndReleasesKeyboardFocus() async throws {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let terminal = MetalTerminalView(frame: frame)
        terminal.automaticallyFocuses = false
        window.contentView = terminal
        #expect(window.makeFirstResponder(terminal))
        #expect(window.firstResponder === terminal)

        terminal.isSelected = false
        terminal.setVisible(false)
        #expect(!terminal.isHidden)
        #expect(window.firstResponder === terminal)
        try await waitUntil { terminal.isHidden }
        #expect(window.firstResponder !== terminal)

        terminal.setVisible(true)
        try await waitUntil { !terminal.isHidden }
        #expect(window.firstResponder !== terminal)
    }

    @Test @MainActor func pendingVisibilityChangesKeepTheLatestRequest() async throws {
        let terminal = MetalTerminalView(frame: .zero)
        terminal.automaticallyFocuses = false
        terminal.setVisible(false)
        terminal.setVisible(true)
        // An unrelated update repeating the same request must not cancel the pending change.
        terminal.setVisible(false)
        terminal.setVisible(false)
        try await waitUntil { terminal.isHidden }

        terminal.setVisible(true)
        terminal.setVisible(false)
        terminal.setVisible(true)
        terminal.setVisible(true)
        try await waitUntil { !terminal.isHidden }
    }

    @Test @MainActor func terminalEnablesMetalWhenAvailable() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }

        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let terminal = MetalTerminalView(frame: frame)
        let font = try #require(NSFont(name: "Menlo-Regular", size: 17.5))
        terminal.applyTwineFont(font)
        window.contentView = terminal

        #expect(terminal.isUsingMetalRenderer)
        #expect(terminal.font == font)
    }
}
