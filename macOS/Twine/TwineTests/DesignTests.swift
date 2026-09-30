import AppKit
import SwiftTerm
import SwiftUI
import Testing

@testable import Twine

@MainActor
struct DesignTests {
    @Test func terminalPaletteResolvesNamedAssetsForEachAppearance() {
        let light = TerminalPalette.resolved(for: NSAppearance(named: .aqua))
        let dark = TerminalPalette.resolved(for: NSAppearance(named: .darkAqua))

        expectRGB(light.background, 0xF7, 0xF4, 0xE8)
        expectRGB(light.text, 0x1A, 0x20, 0x26)
        expectRGB(dark.background, 0x0C, 0x10, 0x13)
        expectRGB(dark.text, 0xE5, 0xE1, 0xCF)
        #expect(light.ansi.count == 16)
        #expect(dark.ansi.count == 16)
        let lightANSI = [
            0x1A2026, 0xB72C32, 0x4C712F, 0x7C6917, 0x176B9B, 0x9F356D, 0x087A60, 0x666354,
            0x626D78, 0xC53B43, 0x517A2D, 0x896A12, 0x00729C, 0xAC467F, 0x007D6A, 0x37382F,
        ]
        let darkANSI = [
            0x1A2026, 0xEF4D4D, 0x8FBE5C, 0xD9BD54, 0x4AA3E0, 0xDC63A0, 0x2DD6AB, 0xCAC5B3,
            0x7D8794, 0xFF8383, 0xA9E488, 0xECD77E, 0x7CD2F5, 0xF0A0D5, 0x85F0D8, 0xF7F4E8,
        ]
        for (color, hex) in zip(light.ansi, lightANSI) {
            expectRGB(color.nsColor, hex >> 16, (hex >> 8) & 0xFF, hex & 0xFF)
        }
        for (color, hex) in zip(dark.ansi, darkANSI) {
            expectRGB(color.nsColor, hex >> 16, (hex >> 8) & 0xFF, hex & 0xFF)
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func terminalTextTonesAreLegible(colorScheme: ColorScheme) {
        let tones: [SwiftUI.Color] = [
            .terminalText, .terminalTextMuted, .terminalTextGreen, .terminalTextBlue, .terminalTextAmber,
        ]
        for tone in tones {
            #expect(contrastRatio(tone, .terminalBackground, in: colorScheme) >= 4.5, "\(tone)")
        }
    }

    /// Log entries show their kind in the role color on the trace detail panel.
    @Test(arguments: [ColorScheme.light, .dark])
    func roleColorsAreLegibleOnSecondarySurfaces(colorScheme: ColorScheme) {
        let roles: [SwiftUI.Color] = [.roleBlue, .roleOrange, .rolePurple, .roleGreen]
        for role in roles {
            #expect(contrastRatio(role, .secondarySurface, in: colorScheme) >= 4.5, "\(role)")
        }
    }
}

private func expectRGB(_ color: NSColor, _ red: Int, _ green: Int, _ blue: Int) {
    #expect(abs(color.redComponent - CGFloat(red) / 255) < 0.0001)
    #expect(abs(color.greenComponent - CGFloat(green) / 255) < 0.0001)
    #expect(abs(color.blueComponent - CGFloat(blue) / 255) < 0.0001)
}

/// The WCAG contrast ratio between two colors resolved in `colorScheme`.
private func contrastRatio(_ first: SwiftUI.Color, _ second: SwiftUI.Color, in colorScheme: ColorScheme) -> Double {
    var environment = EnvironmentValues()
    environment.colorScheme = colorScheme
    func luminance(_ color: SwiftUI.Color) -> Double {
        let resolved = color.resolve(in: environment)
        return 0.2126 * Double(resolved.linearRed) + 0.7152 * Double(resolved.linearGreen)
            + 0.0722 * Double(resolved.linearBlue)
    }
    let (firstLuminance, secondLuminance) = (luminance(first), luminance(second))
    return (max(firstLuminance, secondLuminance) + 0.05) / (min(firstLuminance, secondLuminance) + 0.05)
}
