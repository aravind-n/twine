import Testing

@testable import Twine

@MainActor
struct WindowContentTests {
    private static let noFolders = CoreFolderState(openFolder: nil, recentFolders: [], unavailableFolder: nil)

    @Test func windowShowsNothingUntilTheFirstSnapshot() {
        // Showing the start page here would flash it before the last folder reopens.
        #expect(WindowContent(runState: .idle, snapshot: nil) == .loading)
        #expect(WindowContent(runState: .starting, snapshot: nil) == .loading)
    }

    @Test func windowShowsTheOpenFolderOrTheStartPage() {
        var snapshot = CoreSnapshot.testReady()
        #expect(WindowContent(runState: .running, snapshot: snapshot) == .startPage(Self.noFolders))

        snapshot.folders.openFolder = "/Users/me/project"
        #expect(WindowContent(runState: .running, snapshot: snapshot) == .folder(path: "/Users/me/project"))
        #expect(WindowContent(runState: .failed("No database"), snapshot: snapshot) == .failed("No database"))
    }
}
