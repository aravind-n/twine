import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Twine

@MainActor
struct MemoryModelTests {
    @Test func editOnlyUsesTheFileForTheCurrentSelection() async throws {
        let transport = DeferredMemoryTransport()
        let client = CoreClient(transport: transport)
        let model = MemoryModel()
        let first = memorySource(id: "first.md")
        let second = memorySource(id: "second.md")
        let catalog = Task { await model.load(client: client, folder: nil) }
        try await transport.waitForCatalogs(1)
        await transport.completeCatalog(0, result: .success(.init(sources: [first, second], diagnostics: [])))
        await catalog.value
        model.select(first)
        let read = Task { await model.read(client: client, folder: nil) }
        try await transport.waitForReads(1)
        let file = FilePreview(
            path: first.location, status: .text, text: "first", message: nil,
            version: .init(fingerprint: "first", utf8BOM: false))
        await transport.completeRead(0, result: .success(.init(source: first, text: "first", message: nil, file: file)))
        await read.value
        #expect(model.editableFile == file)
        model.select(second)
        #expect(model.contents?.source.id == first.id)
        #expect(model.editableFile == nil)
    }

    @Test func staleMemoryLinkFailuresDoNotInterruptTheCurrentView() async throws {
        for failCatalog in [true, false] {
            let transport = DeferredMemoryTransport()
            let tabs = FileTabsModel()
            tabs.open(path: "/memory/origin.md", folder: "/memory")
            let source = memorySource(id: "linked.md")
            let task = Task {
                try await tabs.openMemoryLink(
                    URL(filePath: source.location), request: .init(folder: nil),
                    client: CoreClient(transport: transport))
            }
            try await transport.waitForCatalogs(1)
            if failCatalog {
                tabs.showWorkflows()
                await transport.completeCatalog(0, result: .failure(CoreFailure.invalidArgument))
            } else {
                await transport.completeCatalog(0, result: .success(.init(sources: [source], diagnostics: [])))
                try await transport.waitForReads(1)
                tabs.showWorkflows()
                await transport.completeRead(0, result: .failure(CoreFailure.invalidArgument))
            }
            try await task.value
            #expect(tabs.selectedID == nil)
            #expect(tabs.editors.count == 1)
        }
    }

    @Test func pendingMemoryLinkCannotReopenAClosedSourceOrStealSelection() async throws {
        for closeSource in [true, false] {
            let transport = DeferredMemoryTransport()
            let tabs = FileTabsModel()
            let origin = tabs.open(path: "/memory/origin.md", folder: "/memory")
            let source = memorySource(id: "linked.md")
            let task = Task {
                try await tabs.openMemoryLink(
                    URL(filePath: source.location), request: .init(folder: nil),
                    client: CoreClient(transport: transport))
            }
            try await transport.waitForCatalogs(1)
            await transport.completeCatalog(0, result: .success(.init(sources: [source], diagnostics: [])))
            try await transport.waitForReads(1)
            if closeSource {
                #expect(tabs.close(origin.id))
            } else {
                tabs.showWorkflows()
                tabs.select(origin.id)
            }
            let file = FilePreview(path: source.location, status: .text, text: "linked", message: nil, version: nil)
            await transport.completeRead(
                0, result: .success(.init(source: source, text: "linked", message: nil, file: file)))
            try await task.value
            #expect(tabs.editors.count == (closeSource ? 0 : 1))
            #expect(tabs.selectedID == (closeSource ? nil : origin.id))
        }
    }

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
        model.scope = .global
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
        #expect(model.scope == source.scope)
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

    @Test func filtersReconcileSelectionWithinTheCurrentLocation() async throws {
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
        #expect(model.scope == .folder)
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
