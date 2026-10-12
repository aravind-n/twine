import Foundation

extension MemoryHarness {
    nonisolated var title: String { self == .codex ? "Codex" : "Claude Code" }
}

extension MemoryScope {
    nonisolated var title: String {
        switch self {
        case .global: "Global"
        case .folder: "This workspace"
        case .otherFolder: "Other workspaces"
        }
    }
}

extension MemoryKind {
    nonisolated var title: String {
        switch self {
        case .summary: "Summary / index"
        case .durable: "Learned memory"
        case .rawMemory: "Raw memory"
        case .rolloutSummary: "Rollout summary"
        case .instructions: "Instructions"
        case .rule: "Rule"
        case .agentMemory: "Agent memory"
        case .skill: "Memory skill"
        case .extension: "Memory extension"
        case .artifact: "Supporting artifact"
        case .storeStatus: "Store status"
        case .configuration: "Memory settings"
        }
    }
}

extension CoreMemorySource {
    nonisolated var shortPath: String { (location as NSString).abbreviatingWithTildeInPath }
    nonisolated var isMarkdown: Bool { ["md", "markdown"].contains(format.lowercased()) }
    nonisolated var groupTitle: String {
        if group.hasPrefix("Claude folder: ") {
            let key = String(group.dropFirst("Claude folder: ".count))
            let homeKey = NSHomeDirectory().replacingOccurrences(of: "/", with: "-") + "-workspaces-"
            return key.hasPrefix(homeKey) ? String(key.dropFirst(homeKey.count)) : key
        }
        return group.replacingOccurrences(of: "Codex SQLite: ", with: "SQLite · ")
            .replacingOccurrences(of: "Codex ", with: "").replacingOccurrences(of: "Claude ", with: "")
    }
}

extension CoreMemoryRead {
    nonisolated var preview: FilePreview {
        file
            ?? FilePreview(
                path: source.location, status: text == nil ? .unavailable : .text,
                text: text, message: message, version: nil)
    }
}
