/// Holds terminal output read from the bridge until the view for its terminal takes it, within a byte
/// limit shared by all terminals. Output for a closed terminal is dropped, including chunks that
/// arrive after the close.
struct TerminalChunkRouter {
    let capacityBytes: Int
    private var chunksByTerminal: [UInt64: [BridgeTerminalChunk]] = [:]
    private var byteCount = 0
    private var closedTerminalIDs: Set<UInt64> = []

    init(capacityBytes: Int) {
        self.capacityBytes = capacityBytes
    }

    var hasCapacity: Bool {
        byteCount < capacityBytes
    }

    mutating func enqueue(_ chunk: BridgeTerminalChunk) {
        guard !closedTerminalIDs.contains(chunk.terminalID) else { return }
        chunksByTerminal[chunk.terminalID, default: []].append(chunk)
        byteCount += chunk.bytes.count
    }

    mutating func dequeue(for terminalID: UInt64) -> BridgeTerminalChunk? {
        guard var chunks = chunksByTerminal[terminalID], !chunks.isEmpty else { return nil }
        let chunk = chunks.removeFirst()
        byteCount -= chunk.bytes.count
        if chunks.isEmpty {
            chunksByTerminal.removeValue(forKey: terminalID)
        } else {
            chunksByTerminal[terminalID] = chunks
        }
        return chunk
    }

    /// Accepts output for a terminal again, for a started terminal whose ID was closed before.
    mutating func markStarted(_ terminalID: UInt64) {
        closedTerminalIDs.remove(terminalID)
    }

    /// Drops the terminal's buffered output, and any output that arrives for it later.
    mutating func markClosed(_ terminalID: UInt64) {
        closedTerminalIDs.insert(terminalID)
        guard let chunks = chunksByTerminal.removeValue(forKey: terminalID) else { return }
        byteCount -= chunks.reduce(into: 0) { bytes, chunk in
            bytes += chunk.bytes.count
        }
    }

    mutating func removeAll() {
        chunksByTerminal.removeAll()
        byteCount = 0
        closedTerminalIDs.removeAll()
    }
}
