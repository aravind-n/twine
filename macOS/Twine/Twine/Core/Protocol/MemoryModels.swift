import Foundation

nonisolated enum MemoryHarness: String, Codable, CaseIterable, Identifiable {
    case codex, claudeCode
    var id: Self { self }
}

nonisolated enum MemoryScope: String, Codable, CaseIterable, Identifiable {
    case folder, global, otherFolder
    var id: Self { self }
}

nonisolated enum MemoryKind: String, Codable, CaseIterable, Identifiable {
    case summary, durable, rawMemory, rolloutSummary, instructions, rule
    case agentMemory, skill, `extension`, artifact, storeStatus, configuration
    var id: Self { self }
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
