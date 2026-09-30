import AppKit
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
        guard font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace) else {
            terminalLogger.warning("terminal.font_family: font is proportional; using system monospace")
            return fallback
        }
        return font
    }
}
