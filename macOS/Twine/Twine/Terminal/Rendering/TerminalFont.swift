import AppKit
import CoreText
import OSLog

/// Resolves the core's terminal settings once per config, shared by live terminals and history.
enum TerminalFont {
    private static let bundledDescriptor: CTFontDescriptor? = {
        guard let url = Bundle.main.url(forResource: "HackNerdFont-Regular", withExtension: "ttf"),
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            let descriptor = descriptors.first,
            let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
        else { return nil }
        // A family descriptor lets AppKit choose real style faces instead of locking every trait to Regular.
        return CTFontDescriptorCreateWithAttributes(
            [
                kCTFontFamilyNameAttribute as String: family,
                kCTFontRegistrationScopeAttribute as String: CTFontManagerScope.process.rawValue,
                kCTFontTraitsAttribute as String: [kCTFontSymbolicTrait as String: 0],
            ] as CFDictionary)
    }()

    static func resolve(_ config: CoreTerminalConfig) -> NSFont {
        let size = CGFloat(config.fontSize)
        let fallback = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let family = config.fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !family.isEmpty else {
            guard let descriptor = bundledDescriptor else {
                terminalLogger.error("bundled terminal font unavailable; using system monospace")
                return fallback
            }
            return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
        }
        guard let font = installedFont(family: family, size: size) else {
            terminalLogger.warning("terminal.font_family: font unavailable; using system monospace")
            return fallback
        }
        guard hasMatchingCharacterWidths(font) else {
            terminalLogger.warning("terminal.font_family: font failed i/w width check; using system monospace")
            return fallback
        }
        return font
    }

    private static func installedFont(family: String, size: CGFloat) -> NSFont? {
        let query = CTFontDescriptorCreateWithAttributes(
            [
                kCTFontFamilyNameAttribute as String: family,
                kCTFontTraitsAttribute as String: [kCTFontSymbolicTrait as String: 0],
            ] as CFDictionary)
        guard let matches = CTFontDescriptorCreateMatchingFontDescriptors(query, nil) as? [CTFontDescriptor],
            let descriptor = matches.first(where: { candidate in
                guard
                    let candidateFamily = CTFontDescriptorCopyAttribute(candidate, kCTFontFamilyNameAttribute)
                        as? String,
                    candidateFamily.caseInsensitiveCompare(family) == .orderedSame
                else { return false }
                // App-scoped faces support the private fallback's styles; config names select Font Book fonts.
                let scope = CTFontDescriptorCopyAttribute(candidate, kCTFontRegistrationScopeAttribute) as? NSNumber
                return scope?.uint32Value != CTFontManagerScope.process.rawValue
            })
        else { return nil }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as NSFont
    }

    private static func hasMatchingCharacterWidths(_ font: NSFont) -> Bool {
        let characters = Array("iw".utf16)
        let ctFont = font as CTFont
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(ctFont, characters, &glyphs, characters.count) else { return false }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advances, glyphs.count)
        // Compare character advances, not ink bounds or traits affected by wider Nerd Font icons.
        let width = advances[0].width
        return width.isFinite && width > 0 && width == advances[1].width
    }
}

extension NSFont {
    static let terminal = TerminalFont.resolve(.init(fontFamily: "", fontSize: 13))
    static let denseTerminal = TerminalFont.resolve(.init(fontFamily: "", fontSize: 12.5))
}
