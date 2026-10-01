import Foundation
import SwiftTerm

/// Resolve trace byte boundaries through the same ANSI/resize replay as Activity's output viewer.
/// Device replies remain confined to the replay emulator and never reach the live shell.
@MainActor
final class TerminalMinimapReplay {
    let replay: TerminalReplay
    private var anchors: [UInt64: TerminalMinimapAnchor] = [:]

    init(replay: TerminalReplay = TerminalReplay()) { self.replay = replay }

    var rows: [UInt64: Int] { replay.terminal.isCurrentBufferAlternate ? [:] : anchors.mapValues(\.row) }

    func load(
        terminalID: UInt64, endOffset: UInt64, markers: [TraceMinimapMarker], client: CoreClient,
        liveSizes: [CoreTranscriptSize]? = nil, prefix: [TerminalReplayPrefix] = []
    ) async throws {
        for entry in prefix {
            replay.terminal.resize(cols: entry.columns, rows: entry.rows)
            replay.terminal.feed(text: entry.text)
        }
        let ordered = markers.filter { $0.anchor?.terminalID == terminalID }.sorted {
            ($0.anchor?.byteOffset ?? 0) < ($1.anchor?.byteOffset ?? 0)
        }
        var index = 0
        repeat {
            if let liveSizes {
                try replay.applyBoundarySizes(
                    liveSizes.filter { $0.offset == replay.offset }.map {
                        CoreTraceSize(rows: $0.rows, columns: $0.columns)
                    })
                discardExpiredAnchors()
            }
            while index < ordered.count, let anchor = ordered[index].anchor, anchor.byteOffset == replay.offset {
                if liveSizes != nil {
                    if anchor.boundarySizes != nil { capture(id: ordered[index].id) }
                } else {
                    try capture(ordered[index])
                }
                index += 1
            }
            if replay.offset >= endOffset { break }
            let next = index < ordered.count ? ordered[index].anchor?.byteOffset ?? endOffset : endOffset
            let limit = min(64 * 1024, min(next, endOffset) - replay.offset)
            let result = try await client.terminalTranscript(
                terminalID: terminalID, offset: replay.offset, limit: UInt32(max(1, limit)))
            try Task.checkCancellation()
            guard let page = result, page.replayAvailable else { throw ReplayFailure.expired }
            guard page.nextOffset > replay.offset, page.nextOffset <= endOffset else {
                throw CoreFailure.unexpectedCommandResult
            }
            let sizes =
                liveSizes.map { sizes in
                    sizes.filter { $0.offset > page.offset && $0.offset < page.nextOffset }
                } ?? page.sizes
            try replay.append(
                .init(
                    offset: page.offset, nextOffset: page.nextOffset, endOffset: page.endOffset,
                    sizes: sizes, bytes: page.bytes, replayAvailable: page.replayAvailable))
            discardExpiredAnchors()
            await Task.yield()
        } while true
    }

    func capture(id: UInt64) {
        let terminal = replay.terminal
        guard !terminal.isCurrentBufferAlternate else { return }
        // Replay always follows output, so its top row is the current screen's base.
        anchors[id] = TerminalMinimapAnchor(
            terminal: terminal, row: terminal.getTopVisibleRow() + terminal.getCursorLocation().y)
    }

    func capture(_ marker: TraceMinimapMarker) throws {
        guard let anchor = marker.anchor, anchor.byteOffset == replay.offset,
            let sizes = anchor.boundarySizes
        else { return }
        try replay.applyBoundarySizes(sizes)
        discardExpiredAnchors()
        capture(id: marker.id)
    }

    func discardExpiredAnchors() {
        let terminal = replay.terminal
        // Full-screen applications temporarily replace the visible buffer. Their rows cannot
        // represent normal-buffer Activity points, and must not invalidate those retained rows.
        guard !terminal.isCurrentBufferAlternate else { return }
        var rows: [ObjectIdentifier: Int] = [:]
        for row in 0..<TerminalMinimapGeometry.lineCount(in: terminal) {
            if let line = terminal.bufferLine(atRow: row) { rows[ObjectIdentifier(line)] = row }
        }
        anchors = anchors.compactMapValues { anchor in
            var updated = anchor
            return updated.resolve(terminal: terminal, rows: rows) == nil ? nil : updated
        }
    }

    func liveAnchors(in terminal: Terminal) -> [UInt64: TerminalMinimapAnchor] {
        liveAnchors(at: TerminalMinimapCheckpoint(terminal: terminal))
    }

    func liveAnchors(at checkpoint: TerminalMinimapCheckpoint) -> [UInt64: TerminalMinimapAnchor] {
        let recorded = replay.terminal
        guard !recorded.isCurrentBufferAlternate, !checkpoint.alternate,
            recorded.cols == checkpoint.columns, recorded.rows == checkpoint.rows
        else { return [:] }
        return anchors.compactMapValues { anchor in
            let row = anchor.row + recorded.buffer.totalLinesTrimmed - checkpoint.trimmed
            guard checkpoint.lines.indices.contains(row),
                checkpoint.text[row] == anchor.line.translateToString()
            else { return nil }
            return checkpoint.lines[row]
        }
    }

    enum ReplayFailure: Error { case expired }
}
