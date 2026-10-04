import AppKit
import Testing

@testable import Twine

struct AppZoomTests {
    @Test @MainActor func remembersZoomAndResetAndBoundsRepeatedShortcuts() throws {
        let suite = "AppZoomTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let zoom = AppZoom(defaults: defaults)
        #expect(zoom.scale == 1)
        zoom.zoomIn()
        #expect(zoom.scale == 1.1)
        #expect(AppZoom(defaults: defaults).scale == 1.1)
        for _ in 0..<30 { zoom.zoomIn() }
        #expect(zoom.scale == 2)
        #expect(!zoom.canZoomIn)
        for _ in 0..<30 { zoom.zoomOut() }
        #expect(zoom.scale == 0.5)
        #expect(!zoom.canZoomOut)
        zoom.reset()
        #expect(AppZoom(defaults: defaults).scale == 1)
    }

    @Test @MainActor func ignoresInvalidSavedZoom() throws {
        let suite = "AppZoomTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for value in [-100, 0, 101, 900] {
            defaults.set(value, forKey: "interfaceZoomPercent")
            #expect(AppZoom(defaults: defaults).scale == 1)
        }
    }

    @Test @MainActor func shortcutsAcceptPlusAndEqualsWithoutCapturingOrdinaryTyping() throws {
        let suite = "AppZoomTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let zoom = AppZoom(defaults: defaults)
        #expect(zoom.handleKey(try key("=", modifiers: .command)))
        #expect(zoom.scale == 1.1)
        #expect(zoom.handleKey(try key("+", modifiers: [.command, .shift])))
        #expect(zoom.scale == 1.25)
        #expect(zoom.handleKey(try key("-", modifiers: .command)))
        #expect(zoom.scale == 1.1)
        #expect(zoom.handleKey(try key("0", modifiers: .command)))
        #expect(zoom.scale == 1)
        for modifiers: NSEvent.ModifierFlags in [[], .shift, .control, [.command, .option], [.command, .control]] {
            #expect(!zoom.handleKey(try key("=", modifiers: modifiers)))
        }
        #expect(!zoom.handleKey(try key("s", modifiers: .command)))
        #expect(zoom.scale == 1)
    }

    @MainActor private func key(_ character: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: 0))
    }
}
