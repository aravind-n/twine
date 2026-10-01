import AppKit

/// Clipboard images become local files so shells and every harness can use the same paste path.
@MainActor
enum TerminalAttachments {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: types) != nil
    }

    static func text(from pasteboard: NSPasteboard, directory: URL? = nil) throws -> String? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        if let files = urls, !files.isEmpty {
            return files.map { quote($0.path) }.joined(separator: " ") + " "
        }
        guard let type = pasteboard.availableType(from: [.png, .tiff]),
            let data = pasteboard.data(forType: type)
        else { return nil }
        guard let bitmap = NSBitmapImageRep(data: data),
            let png = bitmap.representation(using: .png, properties: [:])
        else { throw AttachmentError.invalidImage }
        let directory = directory ?? FileManager.default.temporaryDirectory.appending(path: "Twine Attachments")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appending(path: "image-\(UUID().uuidString).png")
        try png.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return quote(file.path) + " "
    }

    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private enum AttachmentError: LocalizedError {
        case invalidImage
        var errorDescription: String? { "The clipboard image couldn't be read. Copy it again and retry." }
    }
}
