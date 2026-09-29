import AppKit
import SwiftTerm
import SwiftUI

struct TerminalSurface: View {
    @Environment(BridgeClient.self) private var bridgeClient
    @State private var failureMessage: String?

    let workflow: BridgeWorkflow
    let isSelected: Bool
    var focusRequest = 0
    var beforeUserInput: (() async throws -> Void)?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TerminalViewRepresentable(
                bridgeClient: bridgeClient,
                terminalID: workflow.terminalID,
                isSelected: isSelected,
                focusRequest: focusRequest,
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
        .padding(Spacing.terminalContent)
        .background(.terminalBackground)
    }

    private var statusMessage: String? {
        if let failureMessage { return failureMessage }
        switch bridgeClient.terminalStatus(for: workflow.terminalID) {
        case .exited(let exit):
            if let signal = exit.signal {
                return "Shell exited with code \(exit.exitCode) (\(signal))"
            }
            return "Shell exited with code \(exit.exitCode)"
        case .failed(let message):
            return "Shell failed: \(message)"
        case .running, .none:
            return nil
        }
    }
}

struct TerminalViewRepresentable: NSViewRepresentable {
    let bridgeClient: BridgeClient
    let terminalID: UInt64
    let isSelected: Bool
    let focusRequest: Int
    var beforeUserInput: (() async throws -> Void)?
    @Binding var failureMessage: String?

    func makeCoordinator() -> TerminalController {
        let controller = TerminalController(
            bridgeClient: bridgeClient, terminalID: terminalID, failureMessage: $failureMessage
        )
        controller.beforeUserInput = beforeUserInput
        return controller
    }

    func makeNSView(context: Context) -> MetalTerminalView {
        let view = MetalTerminalView(frame: .zero)
        view.isSelected = isSelected
        view.focusRequest = focusRequest
        view.isHidden = !isSelected
        view.terminalDelegate = context.coordinator
        context.coordinator.start(view: view)
        return view
    }

    func updateNSView(_ nsView: MetalTerminalView, context: Context) {
        context.coordinator.beforeUserInput = beforeUserInput
        nsView.isHidden = !isSelected
        nsView.isSelected = isSelected
        nsView.focusRequest = focusRequest
        nsView.applyTwinePalette()
    }

    static func dismantleNSView(_ nsView: MetalTerminalView, coordinator: TerminalController) {
        nsView.terminalDelegate = nil
        coordinator.stop()
    }
}
