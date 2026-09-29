import AppKit
import MetalKit
import SwiftTerm
import Testing

@testable import Twine

struct MetalTerminalViewTests {
    @Test @MainActor func terminalEnablesMetalWhenAvailable() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }

        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let terminal = MetalTerminalView(frame: frame)
        window.contentView = terminal

        #expect(terminal.isUsingMetalRenderer)
    }
}
