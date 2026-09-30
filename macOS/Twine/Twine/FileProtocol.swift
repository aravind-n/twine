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

    enum Kind: String, Decodable, Sendable {
        case directory, file, symlink, other
    }
}

nonisolated struct FilePreview: Decodable, Equatable, Sendable {
    let path: String
    let status: Status
    let text: String?
    let message: String?

    enum Status: String, Decodable, Sendable {
        case text, binary, tooLarge, missing, unsupported, unavailable
    }
}
