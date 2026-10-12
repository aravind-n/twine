import Foundation

nonisolated struct FileGitSnapshot: Decodable, Equatable, Sendable {
    let repositories: [FileGitRepository]
    let scanning: Bool
    let error: String?
}

nonisolated struct FileGitRepository: Decodable, Equatable, Sendable {
    let root: String
    let changes: [FileGitChange]
    let error: String?
}

nonisolated struct FileGitDecoration: Decodable, Equatable, Sendable {
    let change: FileGitChange?
    let containsChanges: Bool
    let containsConflicts: Bool
    let deleted: Bool
}

nonisolated struct FileGitChange: Decodable, Equatable, Sendable {
    let path: String
    let originalPath: String?
    let staged: FileGitChangeKind?
    let unstaged: FileGitChangeKind?
    let conflicted: Bool
    let untracked: Bool

    var summary: String {
        if conflicted { return "Merge conflict" }
        var parts: [String] = []
        if let staged { parts.append("Staged: \(staged.title)") }
        if let unstaged { parts.append("Unstaged: \(unstaged.title)") }
        if untracked { parts.append("Untracked") }
        return parts.joined(separator: "; ")
    }
}

nonisolated enum FileGitChangeKind: String, Decodable, Sendable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"

    var title: String {
        switch self {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type changed"
        }
    }
}
