import Foundation

nonisolated enum MemoryHarness: String, Codable, CaseIterable, Identifiable {
    case codex, claudeCode
    var id: Self { self }
    var title: String { self == .codex ? "Codex" : "Claude Code" }
}

nonisolated enum MemoryScope: String, Codable, CaseIterable, Identifiable {
    case folder, global, otherFolder
    var id: Self { self }
    var title: String {
        switch self {
        case .global: "Global"
        case .folder: "This workspace"
        case .otherFolder: "Other workspaces"
        }
    }
}

nonisolated enum MemoryKind: String, Codable, CaseIterable, Identifiable {
    case summary, durable, rawMemory, rolloutSummary, instructions, rule
    case agentMemory, skill, `extension`, artifact, storeStatus, configuration
    var id: Self { self }
    var title: String {
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

nonisolated struct CoreMemoryRequest: Encodable, Sendable {
    let folder: String?
    var sourceID: String?
    var examplesRoot: String?
    enum CodingKeys: String, CodingKey {
        case folder
        case sourceID = "sourceId"
        case examplesRoot
    }
}

nonisolated struct CoreMemorySource: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let harness: MemoryHarness
    let scope: MemoryScope
    let kind: MemoryKind
    let location: String
    let group: String
    let format: String
    let modifiedAt: UInt64?
    let example: Bool
    let association: String?
    var shortPath: String { (location as NSString).abbreviatingWithTildeInPath }
    var isMarkdown: Bool { ["md", "markdown"].contains(format.lowercased()) }
    var groupTitle: String {
        if group.hasPrefix("Claude folder: ") {
            let key = String(group.dropFirst("Claude folder: ".count))
            let homeKey = NSHomeDirectory().replacingOccurrences(of: "/", with: "-") + "-workspaces-"
            return key.hasPrefix(homeKey) ? String(key.dropFirst(homeKey.count)) : key
        }
        return group.replacingOccurrences(of: "Codex SQLite: ", with: "SQLite · ")
            .replacingOccurrences(of: "Codex ", with: "").replacingOccurrences(of: "Claude ", with: "")
    }
}

nonisolated struct CoreMemoryCatalog: Decodable, Sendable {
    let sources: [CoreMemorySource]
    let diagnostics: [String]
}

nonisolated struct CoreMemoryRead: Decodable, Sendable {
    let source: CoreMemorySource
    let text: String?
    let message: String?
    var file: FilePreview?
}

nonisolated struct CoreMemorySaveRequest: Encodable, Sendable {
    let source: CoreMemoryRequest
    let text: String
    let expectedVersion: FileVersion
    let overwrite: Bool
}

enum MemoryDisplay: String, CaseIterable {
    case rendered = "Preview"
    case markdown = "Markdown"
}

nonisolated enum MemoryLoadState: Equatable {
    case idle, loading, available
    case failed(String)
}

nonisolated enum MemoryExamples {
    static var root: String {
        if let override = ProcessInfo.processInfo.environment["TWINE_MEMORY_EXAMPLE_ROOT"] { return override }
        return URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "designs/memory-viewer-fixtures").path
    }
}

nonisolated enum MemoryInspection {
    static var opensOnLaunch: Bool {
        #if DEBUG
            ProcessInfo.processInfo.environment["TWINE_MEMORY_PROTOTYPE_LAYOUT"] != nil
                || ProcessInfo.processInfo.environment["TWINE_MEMORY_INSPECTION"] == "1"
        #else
            false
        #endif
    }
    static var harness: MemoryHarness? {
        #if DEBUG
            ProcessInfo.processInfo.environment["TWINE_MEMORY_INSPECTION_HARNESS"].flatMap(
                MemoryHarness.init(rawValue:))
        #else
            nil
        #endif
    }
    static var scope: MemoryScope? {
        #if DEBUG
            ProcessInfo.processInfo.environment["TWINE_MEMORY_INSPECTION_SCOPE"].flatMap(MemoryScope.init(rawValue:))
        #else
            nil
        #endif
    }
    static var kind: MemoryKind? {
        #if DEBUG
            ProcessInfo.processInfo.environment["TWINE_MEMORY_INSPECTION_KIND"].flatMap(MemoryKind.init(rawValue:))
        #else
            nil
        #endif
    }
}
