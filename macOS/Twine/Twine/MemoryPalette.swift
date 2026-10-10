import AppKit
import SwiftUI

/// The warm document and muted outline surfaces from the Source Outline design.
enum MemoryPalette {
    static let document = adaptive(light: 0xFAF9F5, dark: 0x272B2D)
    static let surface = adaptive(light: 0xF5F4EF, dark: 0x2C3133)

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
