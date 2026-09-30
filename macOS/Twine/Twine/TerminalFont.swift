import AppKit
import CoreText
import OSLog

/// Resolves the core's terminal settings once per config, shared by live terminals and history.
enum TerminalFont {
    static func resolve(_ config: CoreTerminalConfig) -> NSFont {
        let size = CGFloat(config.fontSize)
        let fallback = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let family = config.fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !family.isEmpty else { return fallback }
        guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) else {
            terminalLogger.warning("terminal.font_family: font unavailable; using system monospace")
            return fallback
        }
        guard hasMatchingCharacterWidths(font) else {
            terminalLogger.warning("terminal.font_family: font failed i/w width check; using system monospace")
            return fallback
        }
        return font
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
