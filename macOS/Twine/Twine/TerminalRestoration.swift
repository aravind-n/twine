import Foundation
import OSLog
import SwiftTerm

/// Replays recorded geometry off the live input path. Device responses from old output are discarded.
@MainActor
enum TerminalRestoration {
    static func restore(
        history: [UInt64], current: UInt64?, client: CoreClient, view: MetalTerminalView
    ) async throws -> UInt64 {
        for id in history {
            let replay = TerminalReplay()
            do {
                try await pages(id, client: client) { try replay.append($0) }
                feedHistory(
                    replay.text.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n", view: view,
                    source: .init(terminalID: id, byteOffset: replay.offset))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                feedHistory("\r\n[Earlier terminal output is no longer available.]\r\n", view: view)
                terminalLogger.error(
                    "Could not restore terminal \(id): \(error.localizedDescription, privacy: .public)")
            }
        }
        if !history.isEmpty {
            // Move earlier invocations into scrollback before a shell or TUI addresses its screen.
            feedHistory(String(repeating: "\r\n", count: view.getTerminal().rows) + "\u{1B}[H", view: view)
        }
        guard let current else { return 0 }
        var offset: UInt64 = 0
        try await pages(current, client: client) { page in
            var position = page.offset
            for size in page.sizes {
                feed(page, from: position, to: size.offset, view: view)
                view.getTerminal().resize(cols: size.columns, rows: size.rows)
                view.minimapState?.recordSize(columns: size.columns, rows: size.rows)
                position = size.offset
            }
            feed(page, from: position, to: page.nextOffset, view: view)
            offset = page.nextOffset
        }
        return offset
    }

    private static func feedHistory(_ text: String, view: MetalTerminalView, source: CoreTraceAnchor? = nil) {
        view.minimapState?.recordHistory(text, terminal: view.getTerminal(), source: source)
        view.feed(text: text)
    }

    private static func feed(_ page: CoreTranscriptPage, from start: UInt64, to end: UInt64, view: MetalTerminalView) {
        guard start < end else { return }
        view.minimapState?.beginFeed()
        view.feed(byteArray: Array(page.bytes[Int(start - page.offset)..<Int(end - page.offset)])[...])
        view.minimapState?.received(through: end)
    }

    private static func pages(
        _ id: UInt64, client: CoreClient, consume: (CoreTranscriptPage) throws -> Void
    ) async throws {
        var offset: UInt64 = 0
        var end: UInt64?
        repeat {
            let limit = UInt32(min(64 * 1024, end.map { max(1, $0 - offset) } ?? 64 * 1024))
            let page = try await client.terminalTranscript(terminalID: id, offset: offset, limit: limit)
            try Task.checkCancellation()
            guard let page, page.replayAvailable || page.endOffset == 0 else { throw RestorationError.expired }
            if end == nil { end = page.endOffset }
            guard page.offset == offset, page.nextOffset > offset || offset == end else {
                throw CoreFailure.unexpectedCommandResult
            }
            try consume(page)
            offset = page.nextOffset
            await Task.yield()
        } while offset < (end ?? 0)
    }

    private enum RestorationError: Error { case expired }
}
