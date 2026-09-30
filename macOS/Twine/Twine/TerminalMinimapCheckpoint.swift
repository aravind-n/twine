import SwiftTerm

/// Freeze the live row identities and their text at the exact byte offset being replayed. Output
/// may continue while disk reads await; matching against its later screen would lose valid anchors.
@MainActor
struct TerminalMinimapCheckpoint {
    let columns: Int
    let rows: Int
    let trimmed: Int
    let alternate: Bool
    let lines: [TerminalMinimapAnchor]
    let text: [String]

    init(terminal: Terminal) {
        columns = terminal.cols
        rows = terminal.rows
        trimmed = terminal.buffer.totalLinesTrimmed
        alternate = terminal.isCurrentBufferAlternate
        lines = (0..<TerminalMinimapGeometry.lineCount(in: terminal)).compactMap {
            TerminalMinimapAnchor(terminal: terminal, row: $0)
        }
        text = lines.map { $0.line.translateToString() }
    }
}
