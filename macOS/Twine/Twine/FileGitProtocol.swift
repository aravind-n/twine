import Foundation

nonisolated struct FileGitSnapshot: Decodable, Equatable, Sendable {
    let repositories: [FileGitRepository]
    let scanning: Bool
    let error: String?
}

nonisolated struct FileGitRepository: Decodable, Equatable, Identifiable, Sendable {
    let root: String
    let branch: String?
    let upstream: String?
    let ahead: UInt64?
    let behind: UInt64?
    let changes: [FileGitChange]
    let error: String?
    let loading: Bool
    var id: String { root }

    var branchLabel: String {
        branch ?? (loading ? "Reading branch…" : (error == nil ? "Detached HEAD" : "Branch unavailable"))
    }

    var summary: String {
        if loading { return "Reading…" }
        if error != nil { return "Unavailable" }
        return changes.isEmpty ? "Clean" : "\(changes.count) changed"
    }

    var history: String {
        if loading { return "Reading upstream…" }
        if error != nil { return "Upstream unavailable" }
        guard let upstream else { return "No upstream configured" }
        guard let ahead, let behind else { return "Comparison with \(upstream) unavailable" }
        if ahead == 0 && behind == 0 { return "Up to date with \(upstream)" }
        return "\(ahead) ahead · \(behind) behind \(upstream)"
    }
}

nonisolated struct FileGitDecoration: Decodable, Equatable, Sendable {
    let change: FileGitChange?
    let containsChanges: Bool
    let containsConflicts: Bool
    let deleted: Bool
}

nonisolated struct FileGitChange: Decodable, Equatable, Identifiable, Sendable {
    let path: String
    let originalPath: String?
    let staged: FileGitChangeKind?
    let unstaged: FileGitChangeKind?
    let conflicted: Bool
    let untracked: Bool
    var id: String { path }

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
