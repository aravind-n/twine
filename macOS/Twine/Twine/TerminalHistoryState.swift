import Foundation
import Observation

@MainActor
@Observable
final class TerminalHistoryState {
    enum Status {
        case loading
        case ready(TerminalReplay)
        case expired
        case failed(String)
    }

    private(set) var status: Status = .loading

    func load(_ target: TraceTerminalTarget, client: CoreClient) async {
        status = .loading
        guard let boundarySizes = target.anchor.boundarySizes else {
            status = .expired
            return
        }
        let replay = TerminalReplay()
        do {
            // Even an anchor at zero checks retention; an expired prefix cannot be guessed.
            repeat {
                let remaining = target.anchor.byteOffset - replay.offset
                let limit = UInt32(max(1, min(remaining, 64 * 1024)))
                let result = try await client.terminalTranscript(
                    terminalID: target.anchor.terminalID, offset: replay.offset, limit: limit)
                try Task.checkCancellation()
                guard let page = result else {
                    status = .expired
                    return
                }
                guard page.replayAvailable || (target.anchor.byteOffset == 0 && page.endOffset == 0) else {
                    status = .expired
                    return
                }
                if remaining == 0 { break }
                guard page.nextOffset > replay.offset, page.nextOffset <= target.anchor.byteOffset else {
                    throw CoreFailure.unexpectedCommandResult
                }
                try replay.append(page)
                await Task.yield()
            } while replay.offset < target.anchor.byteOffset
            try Task.checkCancellation()
            try replay.applyBoundarySizes(boundarySizes)
            status = .ready(replay)
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { status = .failed(error.localizedDescription) }
        }
    }
}
