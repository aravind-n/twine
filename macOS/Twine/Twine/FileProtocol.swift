import Foundation

nonisolated struct FileBrowserRequest: Encodable, Hashable, Sendable {
    let folder: String
    let directories: [String]
    let file: String?
    var revision: UInt64?
}

nonisolated struct FileBrowserSnapshot: Decodable, Equatable, Sendable {
    let revision: UInt64
    let folder: String
    let directories: [FileDirectory]
    let file: FilePreview?
    let textLimit: UInt64
}

nonisolated struct FileDirectory: Decodable, Equatable, Sendable {
    let path: String
    let entries: [FileEntry]
    let error: String?
}

nonisolated struct FileEntry: Decodable, Equatable, Identifiable, Sendable {
    let path: String
    let name: String
    let kind: Kind
    var id: String { path }

    func relativePath(in folder: String) -> String {
        let root = URL(filePath: folder).standardizedFileURL.pathComponents
        let components = URL(filePath: path).standardizedFileURL.pathComponents
        guard components.starts(with: root) else { return path }
        let relative = components.dropFirst(root.count).joined(separator: "/")
        return relative.isEmpty ? "." : relative
    }

    enum Kind: String, Decodable, Sendable {
        case directory, file, symlink, other
    }
}

nonisolated struct FilePreview: Decodable, Equatable, Sendable {
    let path: String
    let status: Status
    let text: String?
    let message: String?
    var version: FileVersion?

    enum Status: String, Decodable, Sendable {
        case text, binary, tooLarge, missing, unsupported, unavailable
    }
}

nonisolated struct FileVersion: Codable, Equatable, Sendable {
    let fingerprint: String
    let utf8BOM: Bool
}

nonisolated struct FileSaveRequest: Encodable, Sendable {
    let folder: String
    let path: String
    let text: String
    let expectedVersion: FileVersion
    let overwrite: Bool
}

nonisolated struct FileSaveResult: Decodable, Sendable {
    let status: Status
    let file: FilePreview?
    let message: String?

    enum Status: String, Decodable, Sendable { case saved, conflict, failed }
}
