import Foundation
import Testing

@testable import Twine

@MainActor
struct FileTabsTests {
    @Test func memoriesAndFilesShareOneAutosavingBufferInBothDirections() async throws {
        for memoryFirst in [true, false] {
            let tabs = FileTabsModel()
            let file = preview(path: "/folder/.claude/rules/topic.md", text: "original")
            let request = CoreMemoryRequest(folder: "/folder", sourceID: "memory")
            if memoryFirst {
                tabs.openMemory(file, request: request)
            } else {
                tabs.open(path: file.path, folder: "/folder").receive(file)
            }
            let first = try #require(tabs.selected)
            first.text = "unsaved"
            if memoryFirst {
                tabs.open(path: file.path, folder: "/folder")
            } else {
                tabs.openMemory(file, request: request)
            }
            #expect(tabs.selected === first)
            #expect(tabs.editors.count == 1)
            #expect(first.text == "unsaved")
            #expect(first.canAutosave)
            await first.autosave(after: .zero)
            #expect(first.isSaving)
        }
    }

    @Test func switchingAndReopeningKeepIndependentUnsavedBuffers() {
        let tabs = FileTabsModel()
        let first = tabs.open(path: "/folder/first.txt", folder: "/folder")
        first.receive(preview(path: first.path, text: "first"))
        first.text = "first edited"
        let loadID = first.loadID
        let second = tabs.open(path: "/folder/second.txt", folder: "/folder")
        second.receive(preview(path: second.path, text: "second"))
        second.text = "second edited"
        #expect(tabs.selected === second)
        #expect(first.text == "first edited")
        tabs.showWorkflows()
        #expect(tabs.selected == nil)
        #expect(tabs.isDirty)
        let reopened = tabs.open(path: first.path, folder: first.folder)
        #expect(reopened === first)
        #expect(tabs.editors.count == 2)
        #expect(first.loadID == loadID)
        #expect(first.text == "first edited")
        #expect(second.text == "second edited")
        tabs.select(second.id)
        #expect(tabs.selected === second)
    }

    @Test func closingSelectsANeighborAndLeavesBackgroundSelectionAlone() {
        let tabs = FileTabsModel()
        let first = tabs.open(path: "/folder/first", folder: "/folder")
        let second = tabs.open(path: "/folder/second", folder: "/folder")
        let third = tabs.open(path: "/folder/third", folder: "/folder")
        tabs.select(second.id)
        #expect(tabs.close(second.id))
        #expect(tabs.selected === third)
        #expect(tabs.close(third.id))
        #expect(tabs.selected === first)
        tabs.showWorkflows()
        #expect(tabs.close(first.id))
        #expect(tabs.selected == nil)
        #expect(tabs.editors.isEmpty)
    }

    @Test func htmlNavigationReusesTheFileAndUpdatesItsQueryAndFragment() {
        let tabs = FileTabsModel()
        let index = tabs.open(path: "/folder/index.html", folder: "/folder")
        let firstURL = URL(filePath: "/folder/next.html").appending(queryItems: [
            URLQueryItem(name: "mode", value: "one")
        ])
        let next = tabs.open(path: firstURL.path, folder: "/folder", navigationURL: firstURL)
        #expect(tabs.editors.count == 2)
        #expect(index.navigationURL == nil)
        #expect(next.navigationURL == firstURL)
        let secondURL = URL(string: "file:///folder/next.html?mode=two#section")
        let reopened = tabs.open(path: next.path, folder: next.folder, navigationURL: secondURL)
        #expect(reopened === next)
        #expect(tabs.editors.count == 2)
        #expect(next.navigationURL == secondURL)
        let navigationID = next.navigationID
        tabs.open(path: next.path, folder: next.folder, navigationURL: secondURL)
        #expect(next.navigationID != navigationID)
        tabs.select(index.id)
        #expect(next.navigationURL == secondURL)
        #expect(tabs.closeAll())
        #expect(tabs.editors.isEmpty)
        #expect(tabs.selectedID == nil)
    }

    @Test func savingStateIncludesBackgroundFiles() {
        let tabs = FileTabsModel()
        let first = tabs.open(path: "/folder/first", folder: "/folder")
        first.receive(preview(path: first.path, text: "first"))
        first.text = "saved text"
        first.requestSave()
        let second = tabs.open(path: "/folder/second", folder: "/folder")
        #expect(tabs.selected === second)
        #expect(tabs.isSaving)
        #expect(tabs.isDirty)
        tabs.discardAll()
        #expect(tabs.editors.count == 2)
    }

    private func preview(path: String, text: String) -> FilePreview {
        FilePreview(
            path: path, status: .text, text: text, message: nil,
            version: FileVersion(fingerprint: "version", utf8BOM: false))
    }
}
