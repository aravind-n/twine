import SwiftUI

/// Shared role/harness presentation for trace lanes and future agent subtabs.
enum TraceLaneStyle {
    static func color(for lane: BridgeTraceLane) -> Color {
        switch identity(for: lane) {
        case "terminal", "implementer", "codex": return .roleBlue
        case "reviewer", "claude", "claude-code": return .roleOrange
        case "coordinator", "pi": return .rolePurple
        case "worker": return .roleGreen
        default:
            let colors: [Color] = [.roleBlue, .roleOrange, .rolePurple, .roleGreen]
            let hash = identity(for: lane).utf8.reduce(UInt64(1_469_598_103_934_665_603)) {
                ($0 ^ UInt64($1)) &* 1_099_511_628_211
            }
            return colors[Int(hash % UInt64(colors.count))]
        }
    }

    static func symbol(for lane: BridgeTraceLane) -> String {
        switch identity(for: lane) {
        case "terminal": "terminal"
        case "implementer": "hammer"
        case "reviewer": "checkmark.shield"
        case "coordinator": "arrow.triangle.branch"
        case "worker": "person"
        case "codex": "terminal.fill"
        case "claude", "claude-code": "sparkle"
        case "pi": "circle.grid.2x2"
        default: "person.crop.circle"
        }
    }

    private static func identity(for lane: BridgeTraceLane) -> String {
        lane.isAgent ? (lane.role ?? lane.harness ?? lane.name).lowercased() : "terminal"
    }
}
