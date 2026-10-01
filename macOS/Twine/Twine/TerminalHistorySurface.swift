import SwiftUI

struct TerminalHistorySurface: View {
    @Environment(CoreClient.self) private var coreClient
    @Environment(TraceTerminalNavigation.self) private var navigation
    let target: TraceTerminalTarget
    let returnToLive: () -> Void
    @State private var state = TerminalHistoryState()
    @State private var minimap = TerminalMinimapState()

    private var markers: [TraceMinimapMarker] {
        navigation.minimap.markers.filter { $0.anchor?.terminalID == target.anchor.terminalID }
    }

    private var markerKey: String {
        let ready: Bool
        if case .ready = state.status { ready = true } else { ready = false }
        return "\(target.id):\(ready):"
            + markers.map { "\($0.id):\($0.anchor?.byteOffset ?? 0)" }.joined(separator: ",")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                Text(
                    target.timestamp == 0 ? "Saved output" : "Output at \(TraceFormatting.timestamp(target.timestamp))"
                )
                .font(.caption.weight(.semibold))
                Text(target.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button("Return to live", action: returnToLive)
                    .buttonStyle(.glass).controlSize(.small)
                    .accessibilityIdentifier("returnToLive")
            }
            .padding(.horizontal, 14).frame(height: 40)
            Divider()
            switch state.status {
            case .loading:
                ProgressView("Loading terminal output…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready(let replay):
                TerminalHistoryText(
                    text: replay.text, outputStartRange: replay.outputStartRange, font: coreClient.terminalFont,
                    minimap: minimap, markerRows: state.minimapRows
                )
                .padding(.trailing, 18)
                .overlay(alignment: .trailing) {
                    TerminalMinimap(
                        state: minimap, markers: markers, selectedID: navigation.activity.selectedSpanID,
                        select: navigation.selectSpan
                    )
                    .padding(.vertical, 8).padding(.trailing, 3)
                }
            case .expired:
                ContentUnavailableView(
                    "Output no longer available", systemImage: "clock.badge.exclamationmark",
                    description: Text("The history needed to show this moment is no longer available.")
                )
                .accessibilityIdentifier("terminalHistoryExpired")
            case .failed(let message):
                ContentUnavailableView(
                    "Output Couldn't Load", systemImage: "exclamationmark.triangle",
                    description: Text(message))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.terminalBackground)
        .task(id: target.id) { await state.load(target, client: coreClient) }
        .task(id: markerKey) { await state.updateMinimap(markers, target: target, client: coreClient) }
    }
}

#Preview {
    TerminalHistorySurface(
        target: .init(
            workflowID: 1, agentID: nil, anchor: .init(terminalID: 1, byteOffset: 0),
            timestamp: 0, message: "Shell started"), returnToLive: {}
    )
    .environment(CoreClient(transport: CoreWorker(dataDirectory: URL(filePath: NSTemporaryDirectory()))))
    .environment(TraceTerminalNavigation())
}
