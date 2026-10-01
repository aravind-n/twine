import AppKit
import OSLog
import Observation
import SwiftTerm
import SwiftUI

@MainActor
@Observable
final class TerminalMinimapState {
    private(set) var geometry = TerminalMinimapGeometry()
    private(set) var strokes: [CGRect] = []
    private(set) var strokeColors: [SwiftUI.Color] = []
    private(set) var markerRows: [UInt64: Int] = [:]
    private(set) var geometryRevision = 0
    private(set) var indexRevision = 0
    private(set) var receivedOffset: UInt64 = 0
    private(set) var failureMessage: String?
    @ObservationIgnored weak var view: MetalTerminalView?
    @ObservationIgnored weak var historyView: TerminalHistoryScrollView?
    @ObservationIgnored private var historyText = ""
    @ObservationIgnored private var historyLines: [String] = []
    @ObservationIgnored private var anchors: [UInt64: TerminalMinimapAnchor] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var dimensions: CGSize = .zero
    @ObservationIgnored private var unresolved: Set<UInt64> = []
    @ObservationIgnored private var indexing = false
    @ObservationIgnored private var attemptedOffset: UInt64 = 0
    @ObservationIgnored private var liveSizes: [CoreTranscriptSize] = []
    @ObservationIgnored private var isFeeding = false
    @ObservationIgnored private var replayPrefix: [TerminalReplayPrefix] = []

    func recordHistory(_ text: String, terminal: Terminal) {
        replayPrefix.append(.init(text: text, columns: terminal.cols, rows: terminal.rows))
    }

    func recordSize(columns: Int, rows: Int) {
        guard !isFeeding, liveSizes.last?.columns != columns || liveSizes.last?.rows != rows else { return }
        // Replay starts at byte zero, so retain its resize prefix for this view's lifetime.
        liveSizes.append(.init(offset: receivedOffset, rows: rows, columns: columns))
    }

    func beginFeed() {
        if let terminal = view?.getTerminal() { recordSize(columns: terminal.cols, rows: terminal.rows) }
        isFeeding = true
    }

    func received(through offset: UInt64) {
        isFeeding = false
        receivedOffset = offset
        scheduleRefresh()
    }

    func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard let self else { return }
            refreshTask = nil
            refresh()
        }
    }

    func refresh() {
        if let historyView {
            refreshHistory(historyView)
            return
        }
        guard let terminal = view?.getTerminal() else { return }
        recordSize(columns: terminal.cols, rows: terminal.rows)
        let size = CGSize(width: terminal.cols, height: terminal.rows)
        if size != dimensions {
            dimensions = size
            geometryRevision += 1
        }
        let count = TerminalMinimapGeometry.lineCount(in: terminal)
        let font = view?.font ?? .terminal
        let cellWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        geometry = .init(
            rows: count, visibleRows: terminal.rows, topRow: terminal.getTopVisibleRow(), columns: terminal.cols,
            cellAspectRatio: (font.ascender - font.descender + font.leading).rounded(.up) / max(1, cellWidth))
        (strokes, strokeColors) = Self.sample(terminal, count: count)
        if terminal.isCurrentBufferAlternate {
            markerRows = [:]
            return
        }
        var identities: [ObjectIdentifier: Int] = [:]
        for row in 0..<count {
            if let line = terminal.bufferLine(atRow: row) { identities[ObjectIdentifier(line)] = row }
        }
        var resolved: [UInt64: Int] = [:]
        var retained: [UInt64: TerminalMinimapAnchor] = [:]
        for (id, saved) in anchors {
            var anchor = saved
            guard let row = anchor.resolve(terminal: terminal, rows: identities) else { continue }
            resolved[id] = row
            retained[id] = anchor
        }
        anchors = retained
        markerRows = terminal.isCurrentBufferAlternate ? [:] : resolved
        if !indexing, !unresolved.isEmpty, attemptedOffset != receivedOffset {
            attemptedOffset = receivedOffset
            indexRevision += 1
        }
    }

    private static func sample(_ terminal: Terminal, count: Int) -> ([CGRect], [SwiftUI.Color]) {
        var result: [CGRect] = []
        var colors: [SwiftUI.Color] = []
        for row in stride(from: 0, to: count, by: max(1, count / 350)) {
            guard let line = terminal.bufferLine(atRow: row) else { continue }
            let columns = min(line.count, terminal.cols)
            var start: Int?
            for column in 0...columns {
                let character = column < columns ? line[column].getCharacter() : "\0"
                let filled = column < columns && !character.isWhitespace && character != "\0"
                if filled && start == nil { start = column }
                if !filled, let lower = start {
                    result.append(
                        CGRect(
                            x: Double(lower) / Double(max(1, terminal.cols)), y: Double(row) / Double(count),
                            width: Double(column - lower) / Double(max(1, terminal.cols)), height: 0.58 / Double(count))
                    )
                    colors.append(TerminalMinimapInk.color(line[lower].attribute.fg))
                    start = nil
                }
            }
        }
        return (result, colors)
    }

    func scroll(to row: Int) {
        if let scroll = historyView, let text = scroll.documentView as? NSTextView {
            let height = text.layoutManager?.defaultLineHeight(for: text.font ?? .terminal) ?? 16
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, CGFloat(row) * height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            refreshHistory(scroll)
            return
        }
        view?.scrollTo(row: row)
        refresh()
    }

    func returnToLive() { scroll(to: geometry.maximumTop) }

    func showHistory(text: String, rows: [UInt64: Int]) {
        if historyText != text {
            historyText = text
            historyLines = text.components(separatedBy: "\n")
            strokeColors = []
            let count = max(1, historyLines.count)
            let columns = max(1, historyLines.map(\.count).max() ?? 1)
            geometry.columns = columns
            geometry.rows = count
            strokes = stride(from: 0, to: count, by: max(1, count / 350)).compactMap { row in
                let content = historyLines[row].trimmingCharacters(in: .whitespaces)
                guard !content.isEmpty else { return nil }
                return CGRect(
                    x: 0.04, y: Double(row) / Double(count),
                    width: Double(content.count) / Double(columns), height: 0.58 / Double(count))
            }
        }
        markerRows = rows
        if let historyView { refreshHistory(historyView) }
    }

    private func refreshHistory(_ scroll: TerminalHistoryScrollView) {
        guard let text = scroll.documentView as? NSTextView else { return }
        let height = text.layoutManager?.defaultLineHeight(for: text.font ?? .terminal) ?? 16
        geometry = .init(
            rows: max(1, historyLines.count + Int(2 * text.textContainerInset.height / height)),
            visibleRows: max(1, Int(scroll.contentView.bounds.height / height)),
            topRow: max(0, Int(scroll.contentView.bounds.minY / height)), columns: geometry.columns,
            cellAspectRatio: height
                / max(1, ("M" as NSString).size(withAttributes: [.font: text.font ?? .terminal]).width))
    }

    func loadMarkers(_ markers: [TraceMinimapMarker], terminalID: UInt64, client: CoreClient) async {
        unresolved = Set(markers.map(\.id)).subtracting(anchors.keys)
        guard !markers.isEmpty else {
            anchors = [:]
            markerRows = [:]
            return
        }
        let revision = geometryRevision
        let end = receivedOffset
        guard let terminal = view?.getTerminal(), !terminal.isCurrentBufferAlternate else { return }
        let checkpoint = TerminalMinimapCheckpoint(terminal: terminal)
        let sizes = liveSizes
        guard sizes.first?.offset == 0 else { return }
        guard markers.allSatisfy({ ($0.anchor?.byteOffset ?? 0) <= end }) else { return }
        indexing = true
        attemptedOffset = end
        defer {
            indexing = false
            scheduleRefresh()
        }
        do {
            let index = TerminalMinimapReplay()
            try await index.load(
                terminalID: terminalID, endOffset: end, markers: markers, client: client,
                liveSizes: sizes, prefix: replayPrefix)
            try Task.checkCancellation()
            guard revision == geometryRevision else { return }
            accept(index, checkpoint: checkpoint, ids: Set(markers.map(\.id)))
        } catch is CancellationError {
            return
        } catch TerminalMinimapReplay.ReplayFailure.expired {
            guard !Task.isCancelled, revision == geometryRevision else { return }
            anchors = [:]
            markerRows = [:]
            unresolved = []
            failureMessage = "Earlier activity output is no longer available."
        } catch {
            guard !Task.isCancelled, revision == geometryRevision else { return }
            failureMessage = "Activity positions couldn't load."
            terminalLogger.error("Minimap replay failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func accept(_ index: TerminalMinimapReplay, checkpoint: TerminalMinimapCheckpoint, ids: Set<UInt64>) {
        // Preserve surviving live identities while an asynchronous index catches up.
        let mapped = index.liveAnchors(at: checkpoint)
        anchors = anchors.filter { ids.contains($0.key) }.merging(mapped) { _, new in new }
        // Only rows replay can still locate may need a later live checkpoint. Trimmed rows
        // and anchors without geometry cannot recover when more output arrives.
        unresolved = Set(index.rows.keys).subtracting(anchors.keys)
        failureMessage = nil
        refresh()
    }
}
