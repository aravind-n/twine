import Foundation
import Testing

@testable import Twine

@MainActor
struct MemoryNavigationTests {
    @Test func locationsRememberIndependentFiltersSelectionAndScrollAcrossRelaunch() async throws {
        let suite = "MemoryNavigationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MemoryModel(folder: "/project", defaults: defaults)
        try await load(model, sources: sources)
        #expect(model.scope == .folder)
        model.query = "topic"
        model.harness = .claudeCode
        model.kind = .durable
        model.select(sources[1])
        model.rememberScroll(sources[1].id, for: .folder)
        model.isExpanded = true
        model.scope = .global
        model.harness = .codex
        model.select(sources[2])
        model.rememberScroll(sources[2].id, for: .global)
        model.scope = .folder
        #expect(model.query == "topic")
        #expect(model.harness == .claudeCode)
        #expect(model.kind == .durable)
        #expect(model.selectedID == sources[1].id)
        // Collapse leaves the reader selection intact, including after preferences are restored.
        model.isExpanded = false
        let restored = MemoryModel(folder: "/project", defaults: defaults)
        try await load(restored, sources: sources)
        #expect(!restored.isExpanded)
        #expect(restored.selectedID == sources[1].id)
        #expect(restored.query == "topic")
        #expect(restored.scrollID(for: .folder) == sources[1].id)
        restored.scope = .global
        #expect(restored.selectedID == sources[2].id)
        #expect(restored.query.isEmpty)
        #expect(restored.kind == nil)
        #expect(restored.harness == .codex)
        #expect(restored.scrollID(for: .global) == sources[2].id)
        let separate = MemoryModel(folder: "/another-project", defaults: defaults)
        #expect(separate.query.isEmpty)
        #expect(separate.selectedID == nil)
    }

    @Test func otherWorkspaceFilterDisambiguatesFilesAndRecoversAfterRemoval() async throws {
        let model = MemoryModel()
        try await load(model, sources: sources)
        model.scope = .otherFolder
        #expect(model.groups.count == 2)
        model.group = "Claude folder: project-b"
        #expect(model.filteredSources.map(\.id) == ["other-b"])
        #expect(model.selectedID == "other-b")
        model.scope = .folder
        #expect(model.group == nil)
        model.scope = .otherFolder
        #expect(model.group == "Claude folder: project-b")
        try await load(model, sources: sources.filter { $0.id != "other-b" })
        #expect(model.group == nil)
        #expect(model.selectedID == "other-a")
        model.query = "nothing matches"
        #expect(model.selectedID == nil)
    }

    @Test func aCrossLocationLinkRevealsItsDestinationWithoutChangingOriginFilters() async throws {
        let model = MemoryModel()
        try await load(model, sources: sources)
        model.query = "topic"
        model.harness = .claudeCode
        model.openLink(URL(filePath: sources[2].location))
        #expect(model.scope == .global)
        #expect(model.selectedID == sources[2].id)
        #expect(model.filteredSources.contains { $0.id == sources[2].id })
        #expect(model.navigationURL?.path == sources[2].location)
        model.scope = .folder
        #expect(model.query == "topic")
        #expect(model.harness == .claudeCode)
        #expect(model.navigationURL == nil)
    }

    private var sources: [CoreMemorySource] {
        [
            source("index", scope: .folder), source("topic", scope: .folder),
            source("global", scope: .global, harness: .codex),
            source("other-a", scope: .otherFolder, group: "Claude folder: project-a"),
            source("other-b", scope: .otherFolder, group: "Claude folder: project-b"),
        ]
    }

    private func source(
        _ id: String, scope: MemoryScope, harness: MemoryHarness = .claudeCode, group: String = "Memories"
    ) -> CoreMemorySource {
        .init(
            id: id, title: "\(id).md", harness: harness, scope: scope, kind: .durable,
            location: "/memory/\(id).md", group: group, format: "md", modifiedAt: nil, example: false, association: nil)
    }

    private func load(_ model: MemoryModel, sources: [CoreMemorySource]) async throws {
        let transport = DeferredMemoryTransport()
        let task = Task { await model.load(client: CoreClient(transport: transport), folder: "/project") }
        try await transport.waitForCatalogs(1)
        await transport.completeCatalog(0, result: .success(.init(sources: sources, diagnostics: [])))
        await task.value
    }
}
