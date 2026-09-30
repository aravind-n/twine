import AppKit
import SwiftTerm
import SwiftUI

struct TerminalSurface: View {
    /// Two rows of terminal text, which short panels keep by giving up vertical padding first.
    private static let minimumTerminalHeight =
        2 * (NSFont.terminal.ascender - NSFont.terminal.descender + NSFont.terminal.leading).rounded(.up)

    @Environment(CoreClient.self) private var coreClient
    @State private var failureMessage: String?

    let terminalID: UInt64
    /// Hidden terminals keep running without drawing.
    let isVisible: Bool
    /// The selected terminal takes the keyboard.
    let isSelected: Bool
    var focusRequest = 0
    /// Prompt forms above a terminal own automatic keyboard focus until dismissed.
    var automaticallyFocuses = true
    var padding = Spacing.terminalContent
    /// What runs in the terminal, for its exit message.
    var subject = "Shell"
    /// A cancelled agent says so instead of how its process ended.
    var isCancelled = false
    var beforeUserInput: (() async throws -> Void)?
    /// Called after the terminal takes the keyboard, such as when it's clicked.
    var didFocus: (() -> Void)?

    var body: some View {
        TerminalPadding(padding: padding, minimumContentHeight: Self.minimumTerminalHeight) {
            ZStack(alignment: .bottomLeading) {
                TerminalViewRepresentable(
                    coreClient: coreClient,
                    terminalID: terminalID,
                    isVisible: isVisible,
                    isSelected: isSelected,
                    focusRequest: focusRequest,
                    automaticallyFocuses: automaticallyFocuses,
                    didFocus: didFocus,
                    beforeUserInput: beforeUserInput,
                    failureMessage: $failureMessage
                )

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption.monospaced())
                        .foregroundStyle(.terminalTextMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.terminalBackground.opacity(0.92), in: .rect(cornerRadius: 6))
                        .padding(8)
                }
            }
        }
        .background {
            // Clicking the padding focuses the terminal, as clicking its text does.
            Color.terminalBackground.onTapGesture { didFocus?() }
        }
    }

    private var statusMessage: String? {
        if let failureMessage { return failureMessage }
        if isCancelled { return "Agent cancelled" }
        switch coreClient.terminalStatus(for: terminalID) {
        case .exited(let exit):
            if let signal = exit.signal {
                return "\(subject) exited with code \(exit.exitCode) (\(signal))"
            }
            return "\(subject) exited with code \(exit.exitCode)"
        case .failed(let message):
            return "\(subject) failed: \(message)"
        case .running, .none:
            return nil
        }
    }
}

/// Padding around terminal content. Short panels give up vertical padding before the content drops
/// below `minimumContentHeight`. The padding comes from the bounds during layout, not from measured
/// state, so it can't feed back into the window's minimum size.
nonisolated private struct TerminalPadding: Layout {
    let padding: CGFloat
    let minimumContentHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let horizontal = min(padding, bounds.width / 2)
        let vertical = min(padding, max(0, (bounds.height - minimumContentHeight) / 2))
        let content = ProposedViewSize(width: bounds.width - 2 * horizontal, height: bounds.height - 2 * vertical)
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.minX + horizontal, y: bounds.minY + vertical), proposal: content)
        }
    }
}

struct TerminalViewRepresentable: NSViewRepresentable {
    let coreClient: CoreClient
    let terminalID: UInt64
    let isVisible: Bool
    let isSelected: Bool
    let focusRequest: Int
    let automaticallyFocuses: Bool
    var didFocus: (() -> Void)?
    var beforeUserInput: (() async throws -> Void)?
    @Binding var failureMessage: String?

    func makeCoordinator() -> TerminalController {
        let controller = TerminalController(
            coreClient: coreClient, terminalID: terminalID, failureMessage: $failureMessage
        )
        controller.beforeUserInput = beforeUserInput
        return controller
    }

    func makeNSView(context: Context) -> MetalTerminalView {
        let view = MetalTerminalView(frame: .zero)
        view.automaticallyFocuses = automaticallyFocuses
        view.isSelected = isSelected
        view.focusRequest = focusRequest
        view.isHidden = !isVisible
        view.didFocus = didFocus
        view.terminalDelegate = context.coordinator
        context.coordinator.start(view: view)
        return view
    }

    func updateNSView(_ nsView: MetalTerminalView, context: Context) {
        context.coordinator.beforeUserInput = beforeUserInput
        nsView.automaticallyFocuses = automaticallyFocuses
        nsView.didFocus = didFocus
        nsView.isSelected = isSelected
        nsView.focusRequest = focusRequest
        nsView.setVisible(isVisible)
        nsView.applyTwinePalette()
    }

    static func dismantleNSView(_ nsView: MetalTerminalView, coordinator: TerminalController) {
        nsView.terminalDelegate = nil
        coordinator.stop()
    }
}
