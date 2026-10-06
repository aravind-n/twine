import Foundation
import SwiftTerm

/// Resolve trace byte boundaries through the same ANSI/resize replay as Traces' output viewer.
/// Device replies remain confined to the replay emulator and never reach the live shell.
@MainActor
final class TerminalMinimapReplay {
    let replay: TerminalReplay
    private var anchors: [UInt64: TerminalMinimapAnchor] = [:]
    private let includingInput: Bool
    private let prompt: String?
    private var inputText: [UInt64: String] = [:]

    init(replay: TerminalReplay = TerminalReplay(), includingInput: Bool = false, inputText: String? = nil) {
        self.replay = replay
        self.includingInput = includingInput
        prompt = inputText
    }

    var rows: [UInt64: Int] { replay.terminal.isCurrentBufferAlternate ? [:] : anchors.mapValues(\.row) }

    func load(
        terminalID: UInt64, endOffset: UInt64, markers: [TraceMinimapMarker], client: CoreClient,
        liveSizes: [CoreTranscriptSize]? = nil, prefix: [TerminalReplayPrefix] = []
    ) async throws {
        try await load(
            terminalID: terminalID, endOffset: endOffset,
            points: markers.compactMap { marker in marker.anchor.map { (marker.id, $0) } },
            client: client, liveSizes: liveSizes, prefix: prefix,
            prompts: markers.reduce(into: [:]) { $0[$1.id] = $1.inputText })
    }

    func load(
        terminalID: UInt64, endOffset: UInt64, points: [(id: UInt64, anchor: CoreTraceAnchor)], client: CoreClient,
        liveSizes: [CoreTranscriptSize]? = nil, prefix: [TerminalReplayPrefix] = [], prompts: [UInt64: String] = [:],
        prefixPoint: TerminalReplayPrefix.Point? = nil
    ) async throws {
        feedPrefix(prefix, point: prefixPoint)
        let ordered = points.filter { $0.anchor.terminalID == terminalID }.sorted {
            $0.anchor.byteOffset < $1.anchor.byteOffset
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
            while index < ordered.count, ordered[index].anchor.byteOffset == replay.offset {
                let anchor = ordered[index].anchor
                if liveSizes != nil {
                    if anchor.boundarySizes != nil {
                        capture(id: ordered[index].id, prompt: prompts[ordered[index].id])
                    }
                } else {
                    try capture(id: ordered[index].id, anchor: anchor, prompt: prompts[ordered[index].id])
                }
                index += 1
            }
            if replay.offset >= endOffset { break }
            let next = index < ordered.count ? ordered[index].anchor.byteOffset : endOffset
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

    private func feedPrefix(_ prefix: [TerminalReplayPrefix], point: TerminalReplayPrefix.Point?) {
        for entry in prefix {
            replay.terminal.resize(cols: entry.columns, rows: entry.rows)
            if let point, entry.source?.terminalID == point.terminalID {
                let lines = entry.text.components(separatedBy: "\n")
                guard lines.indices.contains(point.row) else {
                    replay.terminal.feed(text: entry.text)
                    continue
                }
                let before = lines.prefix(point.row).joined(separator: "\n") + (point.row > 0 ? "\n" : "")
                replay.terminal.feed(text: before)
                capture(id: point.id)
                replay.terminal.feed(text: lines.dropFirst(point.row).joined(separator: "\n"))
                discardExpiredAnchors()
                if let row = anchors[point.id]?.row {
                    inputText[point.id] = TerminalMinimapGeometry.logicalLine(at: row, in: replay.terminal)
                }
            } else {
                replay.terminal.feed(text: entry.text)
            }
        }
    }

    func capture(id: UInt64, prompt: String? = nil) {
        let terminal = replay.terminal
        guard !terminal.isCurrentBufferAlternate else { return }
        // Replay always follows output, so its top row is the current screen's base.
        let row = terminal.getTopVisibleRow() + terminal.getCursorLocation().y
        let text = prompt ?? self.prompt
        let promptRow = text.flatMap { TerminalMinimapGeometry.inputRow(before: row, matching: $0, in: terminal) }
        let start =
            if text != nil { promptRow ?? row } else {
                includingInput ? TerminalMinimapGeometry.inputRow(before: row, in: terminal) : row
            }
        anchors[id] = TerminalMinimapAnchor(terminal: terminal, row: start)
        if (includingInput && text == nil) || promptRow != nil {
            inputText[id] = TerminalMinimapGeometry.logicalLine(at: start, in: terminal)
        }
    }

    func capture(_ marker: TraceMinimapMarker) throws {
        guard let anchor = marker.anchor else { return }
        try capture(id: marker.id, anchor: anchor, prompt: marker.inputText)
    }

    private func capture(id: UInt64, anchor: CoreTraceAnchor, prompt: String? = nil) throws {
        guard anchor.byteOffset == replay.offset,
            let sizes = anchor.boundarySizes
        else { return }
        try replay.applyBoundarySizes(sizes)
        discardExpiredAnchors()
        capture(id: id, prompt: prompt)
    }

    func discardExpiredAnchors() {
        let terminal = replay.terminal
        // Full-screen applications temporarily replace the visible buffer. Their rows cannot
        // represent normal-buffer trace points, and must not invalidate those retained rows.
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

    /// The mounted terminal can redraw during the disk read. Validate its input just before scrolling.
    func retainsInput(id: UInt64, row: Int, terminal: Terminal) -> Bool {
        guard let expected = inputText[id] else { return !includingInput || prompt != nil }
        return expected == TerminalMinimapGeometry.logicalLine(at: row, in: terminal)
    }

    enum ReplayFailure: Error { case expired }
}
