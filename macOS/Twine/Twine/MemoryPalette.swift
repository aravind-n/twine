import AppKit
import SwiftUI

/// The warm document surface shared by the memory reader and Markdown renderer.
enum MemoryPalette {
    static let document = adaptive(light: 0xFAF9F5, dark: 0x272B2D)

    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(
                    red: CGFloat((value >> 16) & 255) / 255,
                    green: CGFloat((value >> 8) & 255) / 255,
                    blue: CGFloat(value & 255) / 255, alpha: 1)
            })
    }
}
