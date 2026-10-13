import AppKit
import CoreText
import Testing

@testable import Twine

@MainActor
struct TerminalFontTests {
    @Test(arguments: ["TwineMissingFontForTest", "Helvetica", "Arial"], [6.0, 17.5, 72.0])
    func unavailableAndUnequalWidthFamiliesUseSystemMonospace(family: String, size: Double) {
        let font = TerminalFont.resolve(.init(fontFamily: family, fontSize: size))
        #expect(font == NSFont.monospacedSystemFont(ofSize: size, weight: .regular))
    }

    @Test(arguments: ["Menlo", "Courier New", " Menlo "], [6.0, 15.5, 72.0])
    func installedEqualWidthFamiliesResolveAtTheConfiguredSize(family: String, size: Double) {
        let font = TerminalFont.resolve(.init(fontFamily: family, fontSize: size))
        #expect(font.familyName == family.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(font.pointSize == CGFloat(size))
    }

    @Test(arguments: ["", " \n\t"], [6.0, 17.5, 72.0])
    func omittedFamilyUsesThePrivateBundledFace(family: String, size: Double) throws {
        let expectedURL = try #require(Bundle.main.url(forResource: "HackNerdFont-Regular", withExtension: "ttf"))
        let font = TerminalFont.resolve(.init(fontFamily: family, fontSize: size))
        #expect(font.familyName == "Twine Terminal Nerd Font")
        #expect(CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL == expectedURL)
        #expect(font.pointSize == CGFloat(size))
    }

    @Test(arguments: ["Twine Terminal Nerd Font", "Hack Nerd Font"], [6.0, 15.5, 72.0])
    func customFamilyCannotSelectTheBundledCopy(family: String, size: Double) throws {
        let bundledURL = try #require(Bundle.main.url(forResource: "HackNerdFont-Regular", withExtension: "ttf"))
        let font = TerminalFont.resolve(.init(fontFamily: family, fontSize: size))
        #expect(CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL != bundledURL)
        let scope = CTFontCopyAttribute(font as CTFont, kCTFontRegistrationScopeAttribute) as? NSNumber
        #expect(scope?.uint32Value != CTFontManagerScope.process.rawValue)
        #expect(font.pointSize == CGFloat(size))
        for traits: NSFontTraitMask in [.boldFontMask, .italicFontMask, [.boldFontMask, .italicFontMask]] {
            let styled = NSFontManager.shared.convert(font, toHaveTrait: traits)
            let styledScope = CTFontCopyAttribute(styled as CTFont, kCTFontRegistrationScopeAttribute) as? NSNumber
            #expect(styledScope?.uint32Value != CTFontManagerScope.process.rawValue)
        }
    }

    @Test func bundledFontResourcesIncludeEveryFaceAndNerdFontIcons() throws {
        #expect(Bundle.main.object(forInfoDictionaryKey: "ATSApplicationFontsPath") as? String == ".")
        for style in ["Regular", "Bold", "Italic", "BoldItalic"] {
            let url = try #require(Bundle.main.url(forResource: "HackNerdFont-\(style)", withExtension: "ttf"))
            let descriptors = try #require(
                CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
            let descriptor = try #require(descriptors.first)
            let font = CTFontCreateWithFontDescriptor(descriptor, 13, nil)
            #expect(CTFontCopyFamilyName(font) as String == "Twine Terminal Nerd Font")
            #expect(CTFontManagerGetScopeForURL(url as CFURL) == .process)
            let characters = Array("iw\u{e0b0}\u{f07b}".utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            #expect(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count))
            #expect(glyphs.allSatisfy { $0 != 0 })
        }
        #expect(Bundle.main.url(forResource: "HackNerdFont-LICENSE", withExtension: "txt") != nil)
        #expect(Bundle.main.url(forResource: "NerdFonts-LICENSE", withExtension: "txt") != nil)
    }

    @Test func defaultFontHasTheBundledFamilyAndRealBoldAndItalicFaces() {
        let regular = NSFont.terminal
        #expect(regular.familyName == "Twine Terminal Nerd Font")
        #expect(regular.pointSize == 13)
        #expect(NSFont.denseTerminal.familyName == "Twine Terminal Nerd Font")
        for (traits, name) in [
            (NSFontTraitMask.boldFontMask, "TwineHackNF-Bold"),
            (.italicFontMask, "TwineHackNF-Italic"),
            ([.boldFontMask, .italicFontMask], "TwineHackNF-BoldItalic"),
        ] {
            let font = NSFontManager.shared.convert(regular, toHaveTrait: traits)
            #expect(font.fontName == name)
            let url = CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL
            #expect(url?.deletingLastPathComponent().absoluteURL == Bundle.main.resourceURL?.absoluteURL)
        }
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
