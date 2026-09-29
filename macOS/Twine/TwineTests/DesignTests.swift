import SwiftUI
import Testing

@testable import Twine

@MainActor
struct DesignTests {
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
