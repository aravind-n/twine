import AppKit
import MetalKit
import OSLog
import SwiftTerm
import SwiftUI

private let terminalLogger = Logger(subsystem: "com.twineproject.Twine", category: "terminal")

final class MetalTerminalView: TerminalView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard window != nil, !isUsingMetalRenderer else { return }

        do {
            try setUseMetal(true)
        } catch {
            terminalLogger.error("SwiftTerm Metal renderer failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct TerminalSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> MetalTerminalView {
        let view = MetalTerminalView(frame: .zero)
        view.configureNativeColors()
        view.feed(text: "SwiftTerm ready\r\n")
        return view
    }

    func updateNSView(_ nsView: MetalTerminalView, context: Context) {}
}
