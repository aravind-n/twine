import Foundation

nonisolated struct CoreTranscriptSize: Equatable, Sendable {
    let offset: UInt64
    let rows: Int
    let columns: Int
}

nonisolated struct CoreTranscriptPage: Sendable {
    let offset: UInt64
    let nextOffset: UInt64
    let endOffset: UInt64
    let sizes: [CoreTranscriptSize]
    let bytes: Data
    let replayAvailable: Bool

    static func decode(_ data: Data) throws -> Self? {
        var cursor = 0
        func number(_ length: Int) throws -> UInt64 {
            guard cursor + length <= data.count else { throw CoreFailure.unexpectedCommandResult }
            defer { cursor += length }
            return data[cursor..<(cursor + length)].enumerated().reduce(0) { result, item in
                result | (UInt64(item.element) << (item.offset * 8))
            }
        }
        let flags = try number(8)
        if flags == 1 {
            guard data.count == 8 else { throw CoreFailure.unexpectedCommandResult }
            return nil
        }
        guard flags == 0 || flags == 2 else { throw CoreFailure.unexpectedCommandResult }
        let offset = try number(8)
        let next = try number(8)
        let end = try number(8)
        let count = try number(8)
        guard count <= 8192, offset <= next, next <= end, next - offset <= 64 * 1024 else {
            throw CoreFailure.unexpectedCommandResult
        }
        var sizes: [CoreTranscriptSize] = []
        for _ in 0..<count {
            let position = try number(8)
            let rows = try number(2)
            let columns = try number(2)
            _ = try number(2)
            _ = try number(2)
            guard position >= offset, position < next, rows > 0, columns > 0,
                sizes.last.map({ $0.offset <= position }) ?? true
            else { throw CoreFailure.unexpectedCommandResult }
            sizes.append(.init(offset: position, rows: Int(rows), columns: Int(columns)))
        }
        guard data.count - cursor == next - offset else { throw CoreFailure.unexpectedCommandResult }
        return Self(
            offset: offset, nextOffset: next, endOffset: end, sizes: sizes,
            bytes: data.subdata(in: cursor..<data.count), replayAvailable: flags == 2)
    }
}

extension CoreClient {
    func terminalTranscript(terminalID: UInt64, offset: UInt64, limit: UInt32) async throws -> CoreTranscriptPage? {
        try await transport.terminalTranscript(terminalID: terminalID, offset: offset, limit: limit)
    }
}
