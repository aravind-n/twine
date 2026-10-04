import AppKit
import Foundation
import SwiftTerm
import SwiftUI
import Testing

@testable import Twine

@MainActor
struct TerminalPaletteTests {
    @Test func resolvedCorePalettesDecodeFromTheSnapshot() throws {
        let data = Data(
            """
            {"appearance":{"color_scheme":"system"},
             "terminal":{"font_family":"","font_size":13,"colors":{},
              "palettes":{"light":\(Self.paletteJSON),"dark":\(Self.paletteJSON)}}}
            """.utf8)
        let config = try JSONDecoder().decode(CoreConfig.self, from: data)
        #expect(config.terminal.palettes?.light.background == "#123456")
        #expect(config.terminal.palettes?.dark.foreground == "#abcdef")
        #expect(config.terminal.palettes?.light.ansi.count == 16)
    }

    @Test func terminalsApplyCoreColorsBeforeOutputAndFollowAppearanceChanges() {
        let terminal = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        terminal.automaticallyFocuses = false
        terminal.terminalPalettes = Self.palettes
        terminal.appearance = NSAppearance(named: .darkAqua)
        terminal.applyTwinePalette()
        expectColors(terminal, palette: Self.palettes.dark)
        terminal.feed(byteArray: Array("\u{1B}[31mred output".utf8)[...])
        terminal.appearance = NSAppearance(named: .aqua)
        terminal.applyTwinePalette()
        expectColors(terminal, palette: Self.palettes.light)
        #expect(terminal.getTerminal().bufferLine(atRow: 0)?.translateToString(trimRight: true) == "red output")
    }

    @Test func allAnsiSlotsAndMinimapInkUseTheConfiguredPalette() throws {
        let palette = TerminalPalette.resolved(for: NSAppearance(named: .darkAqua), palettes: Self.palettes)
        for index in 0..<16 {
            #expect(palette.ansi[index].nsColor == rgb(Self.palettes.dark.ansi[index]))
            let ink = TerminalMinimapInk.color(.ansi256(code: UInt8(index)), palette: palette)
            let color = try #require(NSColor(ink).usingColorSpace(.sRGB))
            #expect(abs(color.redComponent - palette.ansi[index].nsColor.redComponent) < 0.001)
        }
    }

    @Test func savedOutputUsesTheSameBackgroundAndForegroundWithoutChangingSelection() throws {
        let palette = TerminalPalette.resolved(for: NSAppearance(named: .darkAqua), palettes: Self.palettes)
        let scroll = TerminalHistoryText.makeScrollView()
        TerminalHistoryText.show("saved output", in: scroll, palette: palette)
        let text = try #require(scroll.documentView as? NSTextView)
        text.setSelectedRange(NSRange(location: 0, length: 5))
        TerminalHistoryText.show("saved output", in: scroll, palette: palette)
        #expect(text.backgroundColor == palette.background)
        #expect(text.textColor == palette.text)
        #expect(scroll.backgroundColor == palette.background)
        #expect(text.selectedTextAttributes[.backgroundColor] as? NSColor == palette.selection)
        #expect(text.selectedTextAttributes[.foregroundColor] as? NSColor == palette.text)
        #expect(text.selectedRange() == NSRange(location: 0, length: 5))
    }

    private func expectColors(_ terminal: MetalTerminalView, palette: CoreTerminalPalette) {
        #expect(terminal.nativeBackgroundColor == rgb(palette.background))
        #expect(terminal.nativeForegroundColor == rgb(palette.foreground))
        #expect(terminal.caretColor == rgb(palette.cursor))
        #expect(terminal.selectedTextBackgroundColor == rgb(palette.selection))
        #expect(terminal.selectedTextForegroundColor == rgb(palette.foreground))
    }

    private func rgb(_ hex: String) -> NSColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 255) / 255,
            green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    private static var palettes: CoreTerminalPalettes {
        let ansi = (0..<16).map { String(format: "#%06x", $0 * 0x10101) }
        return CoreTerminalPalettes(
            light: CoreTerminalPalette(
                background: "#fedcba", foreground: "#123456", cursor: "#654321", selection: "#112233", ansi: ansi),
            dark: CoreTerminalPalette(
                background: "#123456", foreground: "#abcdef", cursor: "#ff1234", selection: "#654321", ansi: ansi))
    }

    private static var paletteJSON: String {
        let ansi = Array(repeating: "\"#112233\"", count: 16).joined(separator: ",")
        return """
            {"background":"#123456","foreground":"#abcdef","cursor":"#ff1234","selection":"#654321","ansi":[\(ansi)]}
            """
    }
}
