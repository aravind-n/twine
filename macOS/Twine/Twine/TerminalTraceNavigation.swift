import OSLog
import SwiftUI

/// Reveal Activity in the mounted terminal, or open its saved output when the row is no longer there.
struct TerminalTraceNavigation: ViewModifier {
    @Environment(CoreClient.self) private var client
    @Environment(TraceTerminalNavigation.self) private var navigation
    let terminalID: UInt64
    let historyTerminalIDs: [UInt64]
    let isVisible: Bool
    let minimap: TerminalMinimapState
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
            .task(id: readKey) {
                guard isVisible, let request, handledID != request.id, minimap.geometryRevision > 0 else { return }
                let anchor = request.scrollAnchor
                if anchor.terminalID == terminalID && anchor.byteOffset > minimap.receivedOffset { return }
                do {
                    let found =
                        anchor.terminalID == terminalID
                        ? try await minimap.scroll(
                            to: anchor, includingInput: request.outputStartAnchor != nil, client: client) : false
                    try Task.checkCancellation()
                    navigation.finishScroll(request, found: found)
                    handledID = request.id
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    terminalLogger.error("Trace navigation failed: \(error.localizedDescription, privacy: .public)")
                    navigation.finishScroll(request, found: false)
                    handledID = request.id
                }
            }
    }
}
