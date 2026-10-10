import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Twine

@MainActor
struct MemoryModelTests {
    @Test func nativeMemoryTextIsSelectableAndNeverEditable() {
        let view = MemoryTextView(text: "read-only memory")
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        host.layoutSubtreeIfNeeded()
        let text = findTextView(host)
        #expect(text != nil)
        #expect(text?.isEditable == false)
        #expect(text?.isSelectable == true)
        #expect(text?.allowsUndo == false)
    }

    private func findTextView(_ view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for child in view.subviews { if let text = findTextView(child) { return text } }
        return nil
    }
    @Test func canceledCatalogAndSameSourceReadFailuresCannotReplaceNewResults() async throws {
        let transport = DeferredMemoryTransport()
        let client = CoreClient(transport: transport)
        let model = MemoryModel()
        let old = Task { await model.load(client: client, folder: nil) }
        try await transport.waitForCatalogs(1)
        old.cancel()
        let current = Task { await model.load(client: client, folder: nil) }
        try await transport.waitForCatalogs(2)
        let source = memorySource()
        await transport.completeCatalog(1, result: .success(.init(sources: [source], diagnostics: [])))
        await current.value
        await transport.completeCatalog(0, result: .failure(CoreFailure.invalidArgument))
        await old.value
        #expect(model.state == .available)
        #expect(model.selectedID == source.id)
        #expect(model.expandedGroups.contains(source.group))
        let oldRead = Task { await model.read(client: client, folder: nil) }
        try await transport.waitForReads(1)
        oldRead.cancel()
        let currentRead = Task { await model.read(client: client, folder: nil) }
        try await transport.waitForReads(2)
        await transport.completeRead(1, result: .success(.init(source: source, text: "current", message: nil)))
        await currentRead.value
        await transport.completeRead(0, result: .failure(CoreFailure.invalidArgument))
        await oldRead.value
        #expect(model.readState == .available)
        #expect(model.contents?.text == "current")
    }

    @Test func filtersReconcileSelectionAndRevealItsOutlineGroup() async throws {
        let transport = DeferredMemoryTransport()
        let model = MemoryModel()
        let task = Task { await model.load(client: CoreClient(transport: transport), folder: nil) }
        try await transport.waitForCatalogs(1)
        let global = memorySource(id: "global", scope: .global, group: "User memories")
        let folder = memorySource(id: "folder", scope: .folder, group: "Folder memories")
        await transport.completeCatalog(0, result: .success(.init(sources: [global, folder], diagnostics: [])))
        await task.value
        model.scope = .folder
        model.reconcileSelection()
        #expect(model.filteredSources.map(\.id) == [folder.id])
        #expect(model.selectedID == folder.id)
        #expect(model.expandedScopes.contains(.folder))
        #expect(model.expandedGroups.contains(folder.group))
        model.query = "does-not-exist"
        model.reconcileSelection()
        #expect(model.selectedID == nil)
    }

    private func memorySource(
        id: String = "source", scope: MemoryScope = .global, group: String = "Memories"
    ) -> CoreMemorySource {
        .init(
            id: id, title: "MEMORY.md", harness: .codex, scope: scope, kind: .durable,
            location: "/memory/\(id)", group: group, format: "md", modifiedAt: nil, example: false, association: nil)
    }
}
