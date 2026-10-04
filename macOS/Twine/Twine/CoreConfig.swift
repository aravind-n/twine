import Foundation

nonisolated struct CoreConfig: Decodable, Equatable, Sendable {
    let appearance: CoreAppearance
    let terminal: CoreTerminalConfig

    enum ColorScheme: String, Decodable, Sendable {
        case system
        case light
        case dark
    }
}

nonisolated struct CoreTerminalConfig: Decodable, Equatable, Sendable {
    let fontFamily: String
    let fontSize: Double
    let palettes: CoreTerminalPalettes?

    init(fontFamily: String, fontSize: Double, palettes: CoreTerminalPalettes? = nil) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.palettes = palettes
    }

    private enum CodingKeys: String, CodingKey {
        case fontFamily = "font_family"
        case fontSize = "font_size"
        case palettes
    }
}

nonisolated struct CoreAppearance: Decodable, Equatable, Sendable {
    let colorScheme: CoreConfig.ColorScheme

    private enum CodingKeys: String, CodingKey {
        case colorScheme = "color_scheme"
    }
}

nonisolated struct CoreTerminalPalettes: Decodable, Equatable, Sendable {
    let light: CoreTerminalPalette
    let dark: CoreTerminalPalette
}

nonisolated struct CoreTerminalPalette: Decodable, Equatable, Sendable {
    let background: String
    let foreground: String
    let cursor: String
    let selection: String
    let ansi: [String]
}
