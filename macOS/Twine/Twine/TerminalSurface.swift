import AppKit
import SwiftTerm
import SwiftUI

struct TerminalSurface: View {
    @Environment(BridgeClient.self) private var bridgeClient
    @State private var terminalID: UInt64?
    @State private var failureMessage: String?

    private let workingDirectory: URL

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TerminalViewRepresentable(
                bridgeClient: bridgeClient,
                workingDirectory: workingDirectory,
                terminalID: $terminalID,
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
        .clipShape(panelShape)
        .overlay(panelShape.stroke(.hairline, lineWidth: Surface.hairlineWidth))
        .terminalPanelShadow()
    }

    private var statusMessage: String? {
        if let failureMessage {
            return failureMessage
        }
        guard let terminalID else { return nil }
        switch bridgeClient.terminalStatus(for: terminalID) {
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

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CornerRadius.panel)
    }
}

struct TerminalViewRepresentable: NSViewRepresentable {
    let bridgeClient: BridgeClient
    let workingDirectory: URL
    @Binding var terminalID: UInt64?
    @Binding var failureMessage: String?

    func makeCoordinator() -> TerminalController {
        TerminalController(
            bridgeClient: bridgeClient,
            workingDirectory: workingDirectory,
            terminalID: $terminalID,
            failureMessage: $failureMessage
        )
    }

    func makeNSView(context: Context) -> MetalTerminalView {
        let view = MetalTerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        context.coordinator.start(view: view)
        return view
    }

    func updateNSView(_ nsView: MetalTerminalView, context: Context) {
        nsView.applyTwinePalette()
    }

    static func dismantleNSView(_ nsView: MetalTerminalView, coordinator: TerminalController) {
        nsView.terminalDelegate = nil
        coordinator.stop()
    }
}
