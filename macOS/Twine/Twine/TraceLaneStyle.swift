import SwiftUI

extension EnvironmentValues {
    @Entry var traceLaneColors: [UInt64: Color] = [:]
}

/// Keep role symbols, and distinguish neighboring tracks with stable colors across Activity and minimaps.
enum TraceLaneStyle {
    static func colors(for lanes: [CoreTraceLane], retaining previous: [UInt64: Color] = [:]) -> [UInt64: Color] {
        let palette: [Color] = [.roleBlue, .roleGreen, .rolePurple, .roleOrange]
        // A workflow switch temporarily empties the lanes while its history loads.
        var colors = previous
        var used: [Color] = []
        let ordered = lanes.sorted {
            if (previous[$0.id] != nil) != (previous[$1.id] != nil) { return previous[$0.id] != nil }
            return $0.id < $1.id
        }
        for lane in ordered {
            let preferred = previous[lane.id] ?? color(for: lane)
            colors[lane.id] =
                !used.contains(preferred)
                ? preferred : palette.first(where: { !used.contains($0) }) ?? preferred
            if let assigned = colors[lane.id] { used.append(assigned) }
        }
        return colors
    }

    static func color(for lane: CoreTraceLane, colors: [UInt64: Color] = [:]) -> Color {
        if let color = colors[lane.id] { return color }
        if lane.isAgent, let role = lane.role, role.lowercased() != "agent" { return RoleStyle(role: role).color }
        switch identity(for: lane) {
        case "terminal": return .roleGreen
        case "codex": return .roleBlue
        case "claude", "claude-code": return .roleOrange
        case "pi": return .rolePurple
        case "antigravity": return .roleGreen
        case "omp": return .rolePurple
        case "opencode": return .roleBlue
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
        case "antigravity": "sparkles"
        case "omp": "circle.hexagongrid"
        case "opencode": "chevron.left.forwardslash.chevron.right"
        default: "person.crop.circle"
        }
    }

    private static func identity(for lane: CoreTraceLane) -> String {
        lane.isAgent ? (lane.harness ?? lane.name).lowercased().replacingOccurrences(of: " ", with: "-") : "terminal"
    }
}
