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
    private(set) var minimapRows: [UInt64: Int] = [:]

    func load(_ target: TraceTerminalTarget, client: CoreClient) async {
        status = .loading
        minimapRows = [:]
        guard let boundarySizes = target.anchor.boundarySizes else {
            status = .expired
            return
        }
        let replay = TerminalReplay()
        var endOffset: UInt64? = target.readToCurrentEnd ? nil : target.anchor.byteOffset
        do {
            try markCommandStart(target, replay: replay)
            // Even an anchor at zero checks retention; an expired prefix cannot be guessed.
            repeat {
                let remaining = endOffset.map { $0 - replay.offset } ?? 64 * 1024
                let page = try await retainedPage(target, replay: replay, remaining: remaining, client: client)
                if endOffset == nil { endOffset = page.endOffset }
                if reachedEnd(page, replay: replay, endOffset: endOffset, remaining: remaining) { break }
                guard page.nextOffset > replay.offset, page.nextOffset <= (endOffset ?? 0) else {
                    throw CoreFailure.unexpectedCommandResult
                }
                try replay.append(page)
                try markCommandStart(target, replay: replay)
                await Task.yield()
            } while replay.offset < (endOffset ?? 0)
            try Task.checkCancellation()
            if !target.readToCurrentEnd { try replay.applyBoundarySizes(boundarySizes) }
            status = .ready(replay)
        } catch HistoryFailure.expired {
            status = .expired
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { status = .failed(error.localizedDescription) }
        }
    }
    private enum HistoryFailure: Error { case expired }

    func updateMinimap(_ markers: [TraceMinimapMarker], target: TraceTerminalTarget, client: CoreClient) async {
        guard case .ready(let frozen) = status else { return }
        do {
            let index = TerminalMinimapReplay()
            try await index.load(
                terminalID: target.anchor.terminalID, endOffset: frozen.offset, markers: markers, client: client)
            try Task.checkCancellation()
            if !target.readToCurrentEnd, let sizes = target.anchor.boundarySizes {
                try index.replay.applyBoundarySizes(sizes)
            }
            index.discardExpiredAnchors()
            guard case .ready(let current) = status, current === frozen else { return }
            minimapRows = index.replay.text == frozen.text ? index.rows : [:]
        } catch is CancellationError {
            return
        } catch {
            // Keep the frozen output readable if its backing transcript has since expired.
            guard !Task.isCancelled else { return }
            minimapRows = [:]
        }
    }

    private func reachedEnd(
        _ page: CoreTranscriptPage, replay: TerminalReplay, endOffset: UInt64?, remaining: UInt64
    ) -> Bool {
        remaining == 0 || (page.nextOffset == replay.offset && replay.offset == endOffset)
    }

    private func retainedPage(
        _ target: TraceTerminalTarget, replay: TerminalReplay, remaining: UInt64, client: CoreClient
    ) async throws -> CoreTranscriptPage {
        var readBytes = min(remaining, 64 * 1024)
        if let start = target.outputStartAnchor, start.byteOffset > replay.offset {
            readBytes = min(readBytes, start.byteOffset - replay.offset)
        }
        let page = try await client.terminalTranscript(
            terminalID: target.anchor.terminalID, offset: replay.offset, limit: UInt32(max(1, readBytes)))
        try Task.checkCancellation()
        guard let page, page.replayAvailable || (target.anchor.byteOffset == 0 && page.endOffset == 0) else {
            throw HistoryFailure.expired
        }
        return page
    }

    private func markCommandStart(_ target: TraceTerminalTarget, replay: TerminalReplay) throws {
        guard let start = target.outputStartAnchor, replay.offset == start.byteOffset else { return }
        guard let sizes = start.boundarySizes else { throw HistoryFailure.expired }
        try replay.applyBoundarySizes(sizes)
        replay.markOutputStart(includingInput: true)
    }

}
