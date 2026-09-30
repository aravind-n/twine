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

    private enum CodingKeys: String, CodingKey {
        case fontFamily = "font_family"
        case fontSize = "font_size"
    }
}

nonisolated struct CoreAppearance: Decodable, Equatable, Sendable {
    let colorScheme: CoreConfig.ColorScheme

    private enum CodingKeys: String, CodingKey {
        case colorScheme = "color_scheme"
    }
}
