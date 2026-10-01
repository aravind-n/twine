import AppKit
import Testing

@testable import Twine

@MainActor
struct TerminalAttachmentsTests {
    @Test func clipboardImageCreatesAReadablePrivatePNGWithoutChangingTheClipboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 8, bitsPerPixel: 32))
        bitmap.setColor(.red, atX: 0, y: 0)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        board.setData(png, forType: .png)
        let revision = board.changeCount
        let text = try #require(try TerminalAttachments.text(from: board, directory: directory))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let file = try #require(files.first)
        let saved = try #require(NSBitmapImageRep(data: Data(contentsOf: file)))
        #expect(saved.pixelsWide == 2)
        #expect(saved.pixelsHigh == 2)
        #expect(text == TerminalAttachments.quote(directory.appending(path: file.lastPathComponent).path) + " ")
        #expect(board.changeCount == revision)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func filePastePreservesPathsAndTextPastesFallThrough() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([URL(filePath: "/tmp/a 'quoted' $(file).png") as NSURL])
        #expect(try TerminalAttachments.text(from: board) == "'/tmp/a '\"'\"'quoted'\"'\"' $(file).png' ")
        board.clearContents()
        board.setString("echo ordinary text", forType: .string)
        #expect(!TerminalAttachments.canRead(board))
        #expect(try TerminalAttachments.text(from: board) == nil)
        board.clearContents()
        board.setData(Data([0, 1]), forType: .png)
        #expect(throws: (any Error).self) { try TerminalAttachments.text(from: board) }
    }
}
