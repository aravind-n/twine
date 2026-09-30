import Foundation
import SwiftTerm

/// A separate emulator consumes the complete prefix. Cursor motion and alternate screens are
/// interpreted before a frozen snapshot is shown; window layout never resizes this emulator.
@MainActor
final class TerminalReplay: TerminalDelegate {
    private(set) lazy var terminal = Terminal(delegate: self)
    private(set) var offset: UInt64 = 0

    func append(_ page: BridgeTranscriptPage) throws {
        guard page.offset == offset else { throw BridgeFailure.unexpectedCommandResult }
        var position = page.offset
        for resize in page.sizes {
            feed(page.bytes, from: position - page.offset, to: resize.offset - page.offset)
            terminal.resize(cols: resize.columns, rows: resize.rows)
            position = resize.offset
        }
        feed(page.bytes, from: position - page.offset, to: page.nextOffset - page.offset)
        offset = page.nextOffset
    }

    private func feed(_ bytes: Data, from start: UInt64, to end: UInt64) {
        if start < end { terminal.feed(byteArray: Array(bytes[Int(start)..<Int(end)])) }
    }

    var text: String {
        String(data: terminal.getBufferAsData(), encoding: .utf8) ?? ""
    }

    func applyBoundarySizes(_ sizes: [BridgeTraceSize]) throws {
        for size in sizes {
            guard size.rows > 0, size.columns > 0 else { throw BridgeFailure.unexpectedCommandResult }
            terminal.resize(cols: size.columns, rows: size.rows)
        }
    }

    // Historical device queries must never be sent to a live process.
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
