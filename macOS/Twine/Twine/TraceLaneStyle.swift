import SwiftUI

/// Trace lanes share role presentation with agent subtabs.
enum TraceLaneStyle {
    static func color(for lane: CoreTraceLane) -> Color {
        if lane.isAgent, let role = lane.role { return RoleStyle(role: role).color }
        switch identity(for: lane) {
        case "terminal", "codex": return .roleBlue
        case "claude", "claude-code": return .roleOrange
        case "pi": return .rolePurple
        default:
            let colors: [Color] = [.roleBlue, .roleOrange, .rolePurple, .roleGreen]
            let hash = identity(for: lane).utf8.reduce(UInt64(1_469_598_103_934_665_603)) {
                ($0 ^ UInt64($1)) &* 1_099_511_628_211
            }
            return colors[Int(hash % UInt64(colors.count))]
        }
    }

    static func symbol(for lane: CoreTraceLane) -> String {
        if lane.isAgent, let role = lane.role { return RoleStyle(role: role).symbol }
        return switch identity(for: lane) {
        case "terminal": "terminal"
        case "codex": "terminal.fill"
        case "claude", "claude-code": "sparkle"
        case "pi": "circle.grid.2x2"
        default: "person.crop.circle"
        }
    }

    private static func identity(for lane: CoreTraceLane) -> String {
        lane.isAgent ? (lane.harness ?? lane.name).lowercased().replacingOccurrences(of: " ", with: "-") : "terminal"
    }
}
