import SwiftTerm
import SwiftUI

enum TerminalMinimapInk {
    static func color(_ attribute: Attribute.Color) -> SwiftUI.Color {
        switch attribute {
        case .defaultColor, .defaultInvertedColor: return .terminalTextMuted
        case .trueColor(let red, let green, let blue):
            return SwiftUI.Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
        case .ansi256(let code):
            let palette: [SwiftUI.Color] = [
                .terminalBlack, .terminalTextRed, .terminalTextGreen, .terminalTextAmber,
                .terminalTextBlue, .terminalTextMagenta, .terminalTextCyan, .terminalWhite,
                .terminalTextMuted, .terminalBrightRed, .terminalBrightGreen, .terminalBrightAmber,
                .terminalBrightBlue, .terminalBrightMagenta, .terminalBrightCyan, .terminalBrightWhite,
            ]
            if code < 16 { return palette[Int(code)] }
            if code >= 232 { return SwiftUI.Color(white: Double(8 + 10 * (Int(code) - 232)) / 255) }
            let cube = Int(code) - 16
            let levels = [0.0, 95, 135, 175, 215, 255]
            return SwiftUI.Color(
                red: levels[cube / 36] / 255,
                green: levels[(cube / 6) % 6] / 255, blue: levels[cube % 6] / 255)
        }
    }
}
