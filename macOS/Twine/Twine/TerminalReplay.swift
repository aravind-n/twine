import Foundation
import SwiftTerm

/// A separate emulator consumes the complete prefix. Cursor motion and alternate screens are
/// interpreted before a frozen snapshot is shown; window layout never resizes this emulator.
@MainActor
final class TerminalReplay: TerminalDelegate {
    private(set) lazy var terminal = Terminal(delegate: self)
    private(set) var offset: UInt64 = 0
    private var outputStartLine: BufferLine?
    private var outputStartBuffer: Buffer?

    func markOutputStart() {
        outputStartLine = terminal.bufferLine(atRow: terminal.getTopVisibleRow() + terminal.getCursorLocation().y)
        outputStartBuffer = terminal.buffer
    }

    private var outputStartRow: Int? {
        guard let outputStartLine, outputStartBuffer === terminal.buffer else { return nil }
        var row = 0
        while let line = terminal.bufferLine(atRow: row) {
            if line === outputStartLine { return row }
            row += 1
        }
        return nil
    }

    var outputStartRange: NSRange? {
        guard outputStartBuffer != nil else { return nil }
        // A trimmed command starts at the first retained row, never at a recycled line.
        let row = outputStartRow ?? 0
        let location = text.components(separatedBy: "\n").prefix(row).reduce(0) { $0 + ($1 as NSString).length + 1 }
        let length = (text as NSString).length
        return NSRange(location: min(location, length), length: location < length ? 1 : 0)
    }

    func append(_ page: CoreTranscriptPage) throws {
        guard page.offset == offset else { throw CoreFailure.unexpectedCommandResult }
        var position = page.offset
        for resize in page.sizes {
            feed(page.bytes, from: position - page.offset, to: resize.offset - page.offset)
            applySize(columns: resize.columns, rows: resize.rows)
            position = resize.offset
        }
        feed(page.bytes, from: position - page.offset, to: page.nextOffset - page.offset)
        offset = page.nextOffset
    }

    private func feed(_ bytes: Data, from start: UInt64, to end: UInt64) {
        guard start < end else { return }
        let row = outputStartRow
        let trimmed = terminal.buffer.totalLinesTrimmed
        terminal.feed(byteArray: Array(bytes[Int(start)..<Int(end)]))
        if let row, terminal.buffer.totalLinesTrimmed - trimmed > row { outputStartLine = nil }
        if outputStartRow == nil { outputStartLine = nil }
    }

    private func applySize(columns: Int, rows: Int) {
        terminal.resize(cols: columns, rows: rows)
        if outputStartRow == nil { outputStartLine = nil }
    }

    var text: String {
        String(data: terminal.getBufferAsData(), encoding: .utf8) ?? ""
    }

    func applyBoundarySizes(_ sizes: [CoreTraceSize]) throws {
        for size in sizes {
            guard size.rows > 0, size.columns > 0 else { throw CoreFailure.unexpectedCommandResult }
            applySize(columns: size.columns, rows: size.rows)
        }
    }

    // Historical device queries must never be sent to a live process.
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
