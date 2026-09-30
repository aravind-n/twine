import AppKit
import Testing

@testable import Twine

@MainActor
struct TerminalFontTests {
    @Test(arguments: ["", " \n\t", "TwineMissingFontForTest", "Helvetica"])
    func defaultUnavailableAndProportionalFamiliesUseSystemMonospace(family: String) {
        let font = TerminalFont.resolve(.init(fontFamily: family, fontSize: 17.5))
        #expect(font == NSFont.monospacedSystemFont(ofSize: 17.5, weight: .regular))
    }

    @Test(arguments: ["Menlo", "Courier New", " Menlo "])
    func installedMonospaceFamiliesResolveAtTheConfiguredSize(family: String) {
        let font = TerminalFont.resolve(.init(fontFamily: family, fontSize: 15.5))
        #expect(font.familyName == family.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(font.pointSize == 15.5)
        #expect(font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    @Test func clientResolvesTerminalSettingsFromTheCoreSnapshot() async throws {
        let transport = DelayedStartTransport(snapshot: .testReady(terminal: .init(fontFamily: "Menlo", fontSize: 18)))
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        #expect(client.terminalFont.familyName == "Menlo")
        #expect(client.terminalFont.pointSize == 18)
    }
}
