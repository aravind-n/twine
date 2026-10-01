import AppKit
import Foundation
import SwiftTerm
import Testing

@testable import Twine

@MainActor
struct TerminalReplayTests {
    @Test func replayMatchesCursorEditsResizesAndSplitEscapeSequences() throws {
        let live = MetalTerminalView(frame: .zero)
        let replay = TerminalReplay()
        let chunks = [
            Data("old progress\r\u{1B}[2Kdone\r\n123456789ABC\r\n".utf8),
            Data("\u{1B}[1A\r\u{1B}[2K短い\r\n\u{1B}[31mred\u{1B}[0m".utf8),
            Data("\u{1B}[?1049halt\u{1B}[2;2Hscreen\u{1B}[?1049l".utf8),
        ]
        let sizes = [(10, 4), (6, 3), (12, 5)]
        var offset: UInt64 = 0
        var bytes = Data()
        var resizes: [CoreTranscriptSize] = []
        for (index, chunk) in chunks.enumerated() {
            let (columns, rows) = sizes[index]
            live.resize(cols: columns, rows: rows)
            live.feed(byteArray: Array(chunk)[...])
            resizes.append(.init(offset: offset, rows: rows, columns: columns))
            bytes.append(chunk)
            offset += UInt64(chunk.count)
        }
        // One-byte pages split UTF-8 characters and CSI/OSC sequences. Parser state must survive.
        for position in 0..<bytes.count {
            try replay.append(
                .init(
                    offset: UInt64(position), nextOffset: UInt64(position + 1), endOffset: offset,
                    sizes: resizes.filter { $0.offset == position },
                    bytes: bytes.subdata(in: position..<(position + 1)), replayAvailable: true))
        }
        #expect(replay.text == String(data: live.getTerminal().getBufferAsData(), encoding: .utf8))
        #expect(replay.terminal.getCursorLocation().x == live.getTerminal().getCursorLocation().x)
        #expect(replay.terminal.getCursorLocation().y == live.getTerminal().getCursorLocation().y)
        let frozen = replay.text
        live.resize(cols: 3, rows: 2)
        live.feed(text: "later output")
        #expect(replay.text == frozen)
        #expect(replay.terminal.cols == 12)
        #expect(replay.terminal.rows == 5)
        #expect(!replay.text.contains("old progress"))
        #expect(!replay.text.contains("later output"))
        #expect(!replay.text.contains("screen"))
    }

    @Test func replayRequiresContiguousPages() throws {
        let replay = TerminalReplay()
        #expect(throws: CoreFailure.unexpectedCommandResult) {
            try replay.append(
                .init(offset: 1, nextOffset: 2, endOffset: 2, sizes: [], bytes: Data([65]), replayAvailable: true))
        }
    }

    @Test func commandStartSurvivesEarlierOutputReflowAndRetiresWhenTrimmed() throws {
        let replay = TerminalReplay()
        replay.terminal.changeScrollback(500)
        let prefix = Data((String(repeating: "earlier ", count: 8) + "\r\n").utf8)
        try replay.append(
            .init(
                offset: 0, nextOffset: UInt64(prefix.count), endOffset: UInt64(prefix.count), sizes: [],
                bytes: prefix, replayAvailable: true))
        replay.markOutputStart()
        let output = Data("COMMAND_OUTPUT\r\n".utf8)
        try replay.append(
            .init(
                offset: replay.offset, nextOffset: replay.offset + UInt64(output.count), endOffset: 0,
                sizes: [], bytes: output, replayAvailable: true))
        try replay.applyBoundarySizes([.init(rows: 24, columns: 20)])
        let range = try #require(replay.outputStartRange)
        #expect((replay.text as NSString).substring(from: range.location).hasPrefix("COMMAND_OUTPUT"))
        let flood = Data(String(repeating: "retained\r\n", count: 5000).utf8)
        try replay.append(
            .init(
                offset: replay.offset, nextOffset: replay.offset + UInt64(flood.count), endOffset: 0,
                sizes: [], bytes: flood, replayAvailable: true))
        #expect(!replay.text.contains("COMMAND_OUTPUT"))
        #expect(replay.outputStartRange?.location == 0)
    }
}
