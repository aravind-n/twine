import AppKit
import SwiftTerm
import SwiftUI
import Testing

@testable import Twine

struct AppZoomLayoutTests {
    @Test(arguments: [13.0, 26.0, 72.0], [CoreWorkflow.Kind.terminal, .agents])
    @MainActor func restoredPaneKeepsTwoRowsAtMaximumZoom(fontSize: CGFloat, kind: CoreWorkflow.Kind) async throws {
        let suite = "com.twineproject.Twine.tests.AppZoomLayoutTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(200, forKey: "interfaceZoomPercent")
        let zoom = AppZoom(defaults: defaults)
        let font = try #require(NSFont(name: "Menlo-Regular", size: fontSize))
        let terminal = MetalTerminalView(frame: .zero)
        terminal.automaticallyFocuses = false
        terminal.applyTwineFont(font)
        let workflow = CoreWorkflow(
            workflowID: 1, sessionID: 1, name: "Shell", kind: kind, terminalID: 1,
            agents: kind == .agents
                ? [
                    CoreAgent(agentID: 1, role: "Builder", terminalID: 1),
                    CoreAgent(agentID: 2, role: "Reviewer", terminalID: 2),
                ] : [],
            status: .running, startedAt: 0, endedAt: nil, restored: true)
        let height =
            kind == .agents
            ? WorkflowSurfaceLayout.minimumHeight(for: workflow, font: font)
            : BentoLayout.minimumTerminalPaneHeight(for: font, includesNotice: true)
        let hosting = NSHostingView(
            rootView: VStack(spacing: 0) {
                Text("Shell").frame(height: kind == .agents ? AgentSubtabLayout.height : BentoLayout.headerHeight)
                RestoredWorkflowNotice(workflow: workflow)
                NativeTerminal(view: terminal)
                    .padding(kind == .agents ? Spacing.agentTerminalContent : BentoLayout.terminalPadding)
            }
            .appZoom().environment(\.appZoom, zoom).environment(TraceTerminalNavigation()))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: height * zoom.scale),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await waitUntil { terminal.bounds.height > 0 }
        #expect(terminal.getTerminal().rows >= 2)
        #expect(abs(terminal.convert(terminal.bounds, to: nil).height - terminal.bounds.height * zoom.scale) < 1)
    }

    @Test @MainActor func zoomReflowsRetainedNativeViewsAndPreservesTheKeyboard() async throws {
        let suite = "com.twineproject.Twine.tests.AppZoomLayoutTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let zoom = AppZoom(defaults: defaults)
        let terminal = MetalTerminalView(frame: .zero)
        terminal.automaticallyFocuses = false
        terminal.applyTwineFont(.monospacedSystemFont(ofSize: 13, weight: .regular))
        let hosting = NSHostingView(rootView: NativeTerminal(view: terminal).appZoom().environment(\.appZoom, zoom))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await waitUntil { terminal.bounds.width > 0 }
        let originalWidth = terminal.bounds.width
        let columns = terminal.getTerminal().cols
        #expect(window.makeFirstResponder(terminal))
        terminal.feed(byteArray: Array("retained terminal output".utf8)[...])

        zoom.zoomIn()
        zoom.zoomIn()
        try await waitUntil { abs(terminal.bounds.width - originalWidth / zoom.scale) < 1 }
        #expect(terminal.getTerminal().cols < columns)
        #expect(abs(terminal.convert(terminal.bounds, to: nil).width - originalWidth) < 1)
        #expect(window.firstResponder === terminal)
        #expect(!terminal.getTerminal().getBufferAsData().isEmpty)

        zoom.reset()
        try await waitUntil { abs(terminal.bounds.width - originalWidth) < 1 }
        #expect(terminal.getTerminal().cols == columns)
        #expect(window.firstResponder === terminal)
    }

    @Test @MainActor func intrinsicPresentationSizeIncludesZoomExactlyOnce() throws {
        let hosting = NSHostingView(
            rootView: AppZoomLayout(scale: 1.5) {
                Color.clear.frame(width: 240, height: 160).scaleEffect(1.5, anchor: .topLeading)
            })
        #expect(hosting.fittingSize == CGSize(width: 360, height: 240))
    }
}

private struct NativeTerminal: NSViewRepresentable {
    let view: MetalTerminalView

    func makeNSView(context: Context) -> MetalTerminalView { view }
    func updateNSView(_ nsView: MetalTerminalView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MetalTerminalView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
