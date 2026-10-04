import AppKit
import SwiftTerm
import SwiftUI

struct TerminalPalette {
    let background: NSColor
    let text: NSColor
    let cursor: NSColor
    let selection: NSColor
    let ansi: [SwiftTerm.Color]

    static func resolved(for appearance: NSAppearance?, palettes: CoreTerminalPalettes? = nil) -> Self {
        if let palettes {
            let dark = appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let palette = dark ? palettes.dark : palettes.light
            return Self(
                background: rgb(palette.background), text: rgb(palette.foreground),
                cursor: rgb(palette.cursor), selection: rgb(palette.selection),
                ansi: palette.ansi.map { SwiftTerm.Color(nsColor: rgb($0)) })
        }
        guard let appearance else {
            return fixedPalette()
        }
        var resolved: Self?
        appearance.performAsCurrentDrawingAppearance {
            resolved = fixedPalette()
        }
        return resolved ?? fixedPalette()
    }

    private static func fixedPalette() -> Self {
        let ansi: [NSColor] = [
            .terminalBlack, .terminalTextRed, .terminalTextGreen, .terminalTextAmber,
            .terminalTextBlue, .terminalTextMagenta, .terminalTextCyan, .terminalWhite,
            .terminalTextMuted, .terminalBrightRed, .terminalBrightGreen, .terminalBrightAmber,
            .terminalBrightBlue, .terminalBrightMagenta, .terminalBrightCyan, .terminalBrightWhite,
        ]
        return Self(
            background: fixed(.terminalBackground),
            text: fixed(.terminalText),
            cursor: fixed(.terminalText),
            selection: NSColor(srgbRed: 0, green: 166.0 / 255, blue: 178.0 / 255, alpha: 1),
            ansi: ansi.map { SwiftTerm.Color(nsColor: fixed($0)) }
        )
    }

    private static func rgb(_ hex: String) -> NSColor {
        // Core validates every palette color as #RRGGBB before publishing a snapshot.
        guard let value = UInt32(hex.dropFirst(), radix: 16) else { return .clear }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private static func fixed(_ color: NSColor) -> NSColor {
        guard let resolved = color.usingColorSpace(.sRGB) else { return color }
        return NSColor(
            srgbRed: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent,
            alpha: resolved.alphaComponent
        )
    }
}

/// Resolve terminal presentation from the core snapshot and the enclosing view's appearance.
@propertyWrapper
struct TerminalTheme: DynamicProperty {
    @Environment(CoreClient.self) private var coreClient: CoreClient?
    @Environment(\.colorScheme) private var colorScheme

    var wrappedValue: TerminalPalette {
        TerminalPalette.resolved(
            for: NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua),
            palettes: coreClient?.snapshot?.config.terminal.palettes)
    }
}
