import AppKit
import SwiftUI
import Testing

@testable import Twine

@MainActor
struct DesignTests {
    @Test func terminalPaletteResolvesNamedAssetsForEachAppearance() {
        let light = TerminalPalette.resolved(for: NSAppearance(named: .aqua))
        let dark = TerminalPalette.resolved(for: NSAppearance(named: .darkAqua))

        expectRGB(light.background, 0xF4, 0xF7, 0xF9)
        expectRGB(light.text, 0x23, 0x2C, 0x31)
        expectRGB(light.muted, 0x63, 0x6E, 0x74)
        expectRGB(light.green, 0x25, 0x79, 0x3F)
        expectRGB(light.blue, 0x2B, 0x63, 0xB3)
        expectRGB(light.amber, 0x97, 0x62, 0x13)
        expectRGB(dark.background, 0x13, 0x18, 0x1B)
        expectRGB(dark.text, 0xD8, 0xE1, 0xE6)
        expectRGB(dark.muted, 0x8F, 0x9A, 0xA1)
        expectRGB(dark.green, 0x7F, 0xD0, 0x91)
        expectRGB(dark.blue, 0x80, 0xAE, 0xF2)
        expectRGB(dark.amber, 0xF2, 0xBD, 0x68)
        #expect(light.ansi.count == 16)
        #expect(dark.ansi.count == 16)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func terminalTextTonesAreLegible(colorScheme: ColorScheme) {
        let tones: [Color] = [
            .terminalText, .terminalTextMuted, .terminalTextGreen, .terminalTextBlue, .terminalTextAmber,
        ]
        for tone in tones {
            #expect(contrastRatio(tone, .terminalBackground, in: colorScheme) >= 4.5, "\(tone)")
        }
    }

    /// Log entries show their kind in the role color on the trace detail panel.
    @Test(arguments: [ColorScheme.light, .dark])
    func roleColorsAreLegibleOnSecondarySurfaces(colorScheme: ColorScheme) {
        let roles: [Color] = [.roleBlue, .roleOrange, .rolePurple, .roleGreen]
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
private func contrastRatio(_ first: Color, _ second: Color, in colorScheme: ColorScheme) -> Double {
    var environment = EnvironmentValues()
    environment.colorScheme = colorScheme
    func luminance(_ color: Color) -> Double {
        let resolved = color.resolve(in: environment)
        return 0.2126 * Double(resolved.linearRed) + 0.7152 * Double(resolved.linearGreen)
            + 0.0722 * Double(resolved.linearBlue)
    }
    let (firstLuminance, secondLuminance) = (luminance(first), luminance(second))
    return (max(firstLuminance, secondLuminance) + 0.05) / (min(firstLuminance, secondLuminance) + 0.05)
}
