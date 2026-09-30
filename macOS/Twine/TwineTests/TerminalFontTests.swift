import AppKit
import Testing

@testable import Twine

@MainActor
struct TerminalFontTests {
    @Test(arguments: ["", " \n\t", "TwineMissingFontForTest", "Helvetica", "Arial"], [6.0, 17.5, 72.0])
    func defaultUnavailableAndUnequalWidthFamiliesUseSystemMonospace(family: String, size: Double) {
        let font = TerminalFont.resolve(.init(fontFamily: family, fontSize: size))
        #expect(font == NSFont.monospacedSystemFont(ofSize: size, weight: .regular))
    }

    @Test(arguments: ["Menlo", "Courier New", " Menlo "], [6.0, 15.5, 72.0])
    func installedEqualWidthFamiliesResolveAtTheConfiguredSize(family: String, size: Double) {
        let font = TerminalFont.resolve(.init(fontFamily: family, fontSize: size))
        #expect(font.familyName == family.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(font.pointSize == CGFloat(size))
    }

    @Test(
        .enabled("Requires an installed Hack Nerd Font") {
            await MainActor.run { NSFontManager.shared.availableFontFamilies.contains("Hack Nerd Font") }
        }, arguments: [6.0, 15.5, 72.0])
    func installedNerdFontResolvesUsingCharacterWidths(size: Double) throws {
        let expected = try #require(
            NSFontManager.shared.font(withFamily: "Hack Nerd Font", traits: [], weight: 5, size: size))
        let font = TerminalFont.resolve(.init(fontFamily: "Hack Nerd Font", fontSize: size))
        #expect(font == expected)
        #expect(font.pointSize == CGFloat(size))
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
