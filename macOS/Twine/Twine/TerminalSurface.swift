import AppKit
import SwiftTerm
import SwiftUI

struct TerminalSurface: View {
    @Environment(CoreClient.self) private var coreClient
    @Environment(TraceTerminalNavigation.self) private var navigation
    @State private var failureMessage: String?
    @State private var minimap = TerminalMinimapState()

    private var markers: [TraceMinimapMarker] {
        navigation.minimap.markers.filter { $0.anchor?.terminalID == terminalID }
    }

    private var markerKey: String {
        let latest = markers.compactMap { $0.anchor?.byteOffset }.max() ?? 0
        return "\(terminalID):\(minimap.geometryRevision):\(minimap.receivedOffset >= latest):\(isVisible):"
            + "\(minimap.receivedOffset > 0):\(minimap.indexRevision):"
            + markers.map { String($0.id) }.joined(separator: ",")
    }

    /// Two rows of terminal text, which short panels keep by giving up vertical padding first.
    private var minimumTerminalHeight: CGFloat {
        let font = coreClient.terminalFont
        return 2 * (font.ascender - font.descender + font.leading).rounded(.up)
    }

    let terminalID: UInt64
    var historyTerminalIDs: [UInt64] = []
    var restoresOutput = false
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
    /// The role's lifecycle explains intentional process stops after a completion or handoff.
    var agentStatus: CoreWorkflowRun.AgentStatus?
    var beforeUserInput: (() async throws -> Void)?
    /// Called after the terminal takes the keyboard, such as when it's clicked.
    var didFocus: (() -> Void)?

    var body: some View {
        TerminalPadding(padding: padding, minimumContentHeight: minimumTerminalHeight) {
            ZStack(alignment: .bottomLeading) {
                TerminalViewRepresentable(
                    coreClient: coreClient,
                    font: coreClient.terminalFont,
                    terminalID: terminalID,
                    historyTerminalIDs: historyTerminalIDs,
                    restoresOutput: restoresOutput,
                    isVisible: isVisible,
                    isSelected: isSelected,
                    focusRequest: focusRequest,
                    automaticallyFocuses: automaticallyFocuses,
                    didFocus: didFocus,
                    beforeUserInput: beforeUserInput,
                    minimap: minimap,
                    failureMessage: $failureMessage
                )
                .padding(.trailing, 18)

                if !minimap.geometry.isLive {
                    Button("Return to live", systemImage: "arrow.down") { minimap.returnToLive() }
                        .font(.caption2).buttonStyle(.glass).controlSize(.small)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .accessibilityIdentifier("minimapReturnToLive")
                }

                if let statusMessage {
                    Text(statusMessage)
                        .accessibilityLabel(statusMessage)
                        .accessibilityIdentifier("terminalStatus-\(terminalID)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.terminalTextMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.terminalBackground.opacity(0.92), in: .rect(cornerRadius: 6))
                        .padding(8)
                }
            }
            .overlay(alignment: .trailing) {
                TerminalMinimap(
                    state: minimap, markers: markers, selectedID: navigation.activity.selectedSpanID,
                    select: navigation.selectSpan)
            }
        }
        .background {
            // Clicking the padding focuses the terminal, as clicking its text does.
            Color.terminalBackground.onTapGesture { didFocus?() }
        }
        .task(id: markerKey) {
            if isVisible { await minimap.loadMarkers(markers, terminalID: terminalID, client: coreClient) }
        }
        .accessibilityHidden(!isVisible)
    }

    private var statusMessage: String? {
        TerminalStatusMessage.text(
            subject: subject, terminalStatus: coreClient.terminalStatus(for: terminalID),
            agentStatus: agentStatus, isCancelled: isCancelled, failureMessage: failureMessage)
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
    let font: NSFont
    let terminalID: UInt64
    var historyTerminalIDs: [UInt64] = []
    var restoresOutput = false
    let isVisible: Bool
    let isSelected: Bool
    let focusRequest: Int
    let automaticallyFocuses: Bool
    var didFocus: (() -> Void)?
    var beforeUserInput: (() async throws -> Void)?
    var minimap: TerminalMinimapState?
    @Binding var failureMessage: String?

    func makeCoordinator() -> TerminalController {
        let controller = TerminalController(
            coreClient: coreClient, terminalID: terminalID, failureMessage: $failureMessage
        )
        controller.beforeUserInput = beforeUserInput
        controller.historyTerminalIDs = historyTerminalIDs
        controller.restoresOutput = restoresOutput
        return controller
    }

    func makeNSView(context: Context) -> MetalTerminalView {
        let view = MetalTerminalView(frame: .zero)
        view.applyTwineFont(font)
        view.automaticallyFocuses = automaticallyFocuses
        view.isSelected = isSelected
        view.focusRequest = focusRequest
        view.isHidden = !isVisible
        view.didFocus = didFocus
        view.minimapState = minimap
        minimap?.view = view
        view.terminalDelegate = context.coordinator
        context.coordinator.start(view: view)
        return view
    }

    func updateNSView(_ nsView: MetalTerminalView, context: Context) {
        nsView.applyTwineFont(font)
        context.coordinator.beforeUserInput = beforeUserInput
        nsView.automaticallyFocuses = automaticallyFocuses
        nsView.didFocus = didFocus
        nsView.isSelected = isSelected
        nsView.focusRequest = focusRequest
        nsView.setVisible(isVisible)
        nsView.applyTwinePalette()
        minimap?.scheduleRefresh()
    }

    static func dismantleNSView(_ nsView: MetalTerminalView, coordinator: TerminalController) {
        nsView.terminalDelegate = nil
        coordinator.stop()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MetalTerminalView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
