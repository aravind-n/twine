import SwiftTerm
import SwiftUI

enum TerminalMinimapInk {
    static func color(_ attribute: Attribute.Color, palette: TerminalPalette? = nil) -> SwiftUI.Color {
        switch attribute {
        case .defaultColor, .defaultInvertedColor:
            return palette.map { SwiftUI.Color(nsColor: $0.text) } ?? .terminalTextMuted
        case .trueColor(let red, let green, let blue):
            return SwiftUI.Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
        case .ansi256(let code):
            if code < 16, let palette { return SwiftUI.Color(nsColor: palette.ansi[Int(code)].nsColor) }
            let colors: [SwiftUI.Color] = [
                .terminalBlack, .terminalTextRed, .terminalTextGreen, .terminalTextAmber,
                .terminalTextBlue, .terminalTextMagenta, .terminalTextCyan, .terminalWhite,
                .terminalTextMuted, .terminalBrightRed, .terminalBrightGreen, .terminalBrightAmber,
                .terminalBrightBlue, .terminalBrightMagenta, .terminalBrightCyan, .terminalBrightWhite,
            ]
            if code < 16 { return colors[Int(code)] }
            if code >= 232 { return SwiftUI.Color(white: Double(8 + 10 * (Int(code) - 232)) / 255) }
            let cube = Int(code) - 16
            let levels = [0.0, 95, 135, 175, 215, 255]
            return SwiftUI.Color(
                red: levels[cube / 36] / 255,
                green: levels[(cube / 6) % 6] / 255, blue: levels[cube % 6] / 255)
        }
    }
}
