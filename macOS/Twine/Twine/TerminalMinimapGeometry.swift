import CoreGraphics
import Foundation
import SwiftTerm

nonisolated struct TerminalMinimapGeometry: Equatable {
    var rows = 1
    var visibleRows = 1
    var topRow = 0

    var maximumTop: Int { max(0, rows - visibleRows) }
    var isLive: Bool { topRow >= maximumTop }
    var viewport: ClosedRange<Double> {
        Double(topRow) / Double(max(1, rows))...min(1, Double(topRow + visibleRows) / Double(max(1, rows)))
    }

    func row(at fraction: Double) -> Int {
        max(0, min(maximumTop, Int((fraction * Double(rows)).rounded()) - visibleRows / 2))
    }

    static func strokeRect(_ stroke: CGRect, in size: CGSize, expanded: Bool) -> CGRect {
        // Only the expanded rail reserves a lane for numbered Activity points. Applying
        // that gutter to the 14pt rail collapses every word into a single pixel.
        let inset: CGFloat = expanded ? 4 : 2
        let trailing: CGFloat = expanded ? 11 : 2
        let width = max(1, size.width - inset - trailing)
        return CGRect(
            x: inset + stroke.minX * width, y: stroke.minY * size.height,
            width: max(0.7, stroke.width * width), height: max(0.7, stroke.height * size.height))
    }

    @MainActor static func lineCount(in terminal: Terminal) -> Int {
        var lower = 0
        var upper = max(1, terminal.rows)
        while terminal.bufferLine(atRow: upper) != nil { upper *= 2 }
        while lower < upper {
            let middle = (lower + upper) / 2
            if terminal.bufferLine(atRow: middle) == nil { upper = middle } else { lower = middle + 1 }
        }
        return max(1, lower)
    }
}

/// A line identity survives ordinary output and reflow; trimming must invalidate it before SwiftTerm
/// recycles the object into a different row. Never infer a terminal row from a byte percentage.
@MainActor
struct TerminalMinimapAnchor {
    let line: BufferLine
    let buffer: Buffer
    private(set) var row: Int
    private var trimmed: Int

    init?(terminal: Terminal, row: Int) {
        guard let line = terminal.bufferLine(atRow: row) else { return nil }
        self.line = line
        buffer = terminal.buffer
        self.row = row
        trimmed = buffer.totalLinesTrimmed
    }

    mutating func resolve(terminal: Terminal, rows: [ObjectIdentifier: Int]) -> Int? {
        guard buffer === terminal.buffer, buffer.totalLinesTrimmed >= trimmed,
            buffer.totalLinesTrimmed - trimmed <= row,
            let current = rows[ObjectIdentifier(line)]
        else { return nil }
        row = current
        trimmed = buffer.totalLinesTrimmed
        return row
    }
}
