import SwiftUI

/// Activity jumps keep the terminal interactive. Saved output is an explicit fallback when a point
/// belongs to an older invocation or has left the live scrollback.
struct TerminalTraceNavigation: ViewModifier {
    @Environment(CoreClient.self) private var client
    @Environment(TraceTerminalNavigation.self) private var navigation
    let terminalID: UInt64
    let historyTerminalIDs: [UInt64]
    let isVisible: Bool
    let minimap: TerminalMinimapState
    @State private var unavailable: TraceTerminalTarget?
    @State private var handledID: UUID?

    private var request: TraceTerminalTarget? {
        navigation.scrollTarget.flatMap {
            $0.anchor.terminalID == terminalID || historyTerminalIDs.contains($0.anchor.terminalID) ? $0 : nil
        }
    }

    private var readKey: String {
        let ready = request.map { $0.scrollAnchor.byteOffset <= minimap.receivedOffset } ?? false
        return "\(request?.id.uuidString ?? ""):\(isVisible):\(ready):\(minimap.geometryRevision)"
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let unavailable, unavailable.id == request?.id {
                    HStack(spacing: 8) {
                        Text("This point is outside the current terminal scrollback.")
                        Button("Show saved output") {
                            navigation.scrollTarget = nil
                            navigation.target = unavailable
                        }
                        Button("Dismiss", systemImage: "xmark") { self.unavailable = nil }
                            .labelStyle(.iconOnly)
                    }
                    .font(.caption).padding(8)
                    .background(.regularMaterial, in: .rect(cornerRadius: 8)).padding(8)
                    .accessibilityIdentifier("traceScrollUnavailable")
                }
            }
            .task(id: readKey) {
                guard isVisible, let request, handledID != request.id, minimap.geometryRevision > 0 else { return }
                let anchor = request.scrollAnchor
                if anchor.terminalID == terminalID && anchor.byteOffset > minimap.receivedOffset { return }
                do {
                    let found =
                        anchor.terminalID == terminalID ? try await minimap.scroll(to: anchor, client: client) : false
                    try Task.checkCancellation()
                    unavailable = found ? nil : request
                    handledID = request.id
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    unavailable = request
                    handledID = request.id
                }
            }
    }
}
