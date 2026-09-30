import SwiftUI

/// The one stable color and SF Symbol a role has everywhere it appears, such as its agent subtab.
struct RoleStyle: Equatable {
    let color: Color
    let symbol: String

    init(role: String) {
        let parts = role.lowercased().split(separator: " ")
        let baseRole =
            parts.last.flatMap { Int($0) } == nil ? role.lowercased() : parts.dropLast().joined(separator: " ")
        switch baseRole {
        case "implementer": (color, symbol) = (.roleBlue, "hammer")
        case "reviewer": (color, symbol) = (.roleOrange, "checkmark.bubble")
        case "coordinator": (color, symbol) = (.rolePurple, "flowchart")
        case "worker": (color, symbol) = (.roleGreen, "wrench.and.screwdriver")
        // Roles from user-made workflow types get their own colors when those types arrive.
        default: (color, symbol) = (.secondary, "person")
        }
    }
}
