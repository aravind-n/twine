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

        expectRGB(light.background, 0xFF, 0xFF, 0xFF)
        expectRGB(light.text, 0x32, 0x25, 0x29)
        expectRGB(light.cursor, 0x00, 0x7A, 0xFF)
        expectRGB(light.selection, 0xB3, 0xD7, 0xFF)
        expectRGB(dark.background, 0x26, 0x26, 0x26)
        expectRGB(dark.text, 0xFA, 0xF1, 0xF3)
        expectRGB(dark.cursor, 0x00, 0x7A, 0xFF)
        expectRGB(dark.selection, 0x3F, 0x63, 0x8B)
        #expect(light.ansi.count == 16)
        #expect(dark.ansi.count == 16)
        let lightANSI = [
            0x322529, 0xCA2C1D, 0x00856F, 0x906918, 0x0049C1, 0xC4246E, 0x007E9E, 0x322529,
            0x6A7084, 0xCC2623, 0x00695C, 0x765300, 0x0078B8, 0x9D31CF, 0x006279, 0x000000,
        ]
        let darkANSI = [
            0x1C1C1C, 0xFF8D7A, 0x00D9B2, 0xEBA800, 0x5B98E6, 0xFF82B3, 0x00CAFA, 0xFAF1F3,
            0xABB3CD, 0xFFAEA0, 0x00DF75, 0xFFD166, 0x82B7FF, 0xD896FE, 0x62E3FF, 0xFFFFFF,
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

    @Test(arguments: [ColorScheme.light, .dark])
    func terminalSelectionKeepsTextLegible(colorScheme: ColorScheme) {
        #expect(contrastRatio(.terminalText, .terminalSelection, in: colorScheme) >= 4.5)
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
