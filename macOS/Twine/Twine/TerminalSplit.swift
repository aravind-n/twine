import CoreGraphics
import Foundation

/// A presentation tree over durable workflows. Splitting creates a normal core-owned terminal.
nonisolated indirect enum TerminalSplit: Codable, Equatable, Sendable {
    enum Direction: String, Codable, Sendable { case right, down }
    case pane(UInt64)
    case branch(UUID, Direction, Double, TerminalSplit, TerminalSplit)

    var ids: [UInt64] {
        switch self {
        case .pane(let id): [id]
        case .branch(_, _, _, let first, let second): first.ids + second.ids
        }
    }

    func minimumHeight(paneHeight: CGFloat) -> CGFloat {
        switch self {
        case .pane: paneHeight
        case .branch(_, let direction, _, let first, let second):
            direction == .down
                ? first.minimumHeight(paneHeight: paneHeight) + BentoLayout.gutter
                    + second.minimumHeight(paneHeight: paneHeight)
                : max(first.minimumHeight(paneHeight: paneHeight), second.minimumHeight(paneHeight: paneHeight))
        }
    }

    func inserting(_ newID: UInt64, beside id: UInt64, direction: Direction) -> Self {
        switch self {
        case .pane(let existing):
            return existing == id ? .branch(UUID(), direction, 0.5, self, .pane(newID)) : self
        case .branch(let key, let axis, let fraction, let first, let second):
            return .branch(
                key, axis, fraction, first.inserting(newID, beside: id, direction: direction),
                second.inserting(newID, beside: id, direction: direction))
        }
    }

    func retaining(_ open: Set<UInt64>) -> Self? {
        switch self {
        case .pane(let id): return open.contains(id) ? self : nil
        case .branch(let key, let axis, let fraction, let first, let second):
            let left = first.retaining(open)
            let right = second.retaining(open)
            if let left, let right { return .branch(key, axis, fraction, left, right) }
            return left ?? right
        }
    }

    func resizing(_ divider: UUID, fraction: Double) -> Self {
        switch self {
        case .pane: return self
        case .branch(let key, let axis, let old, let first, let second):
            return .branch(
                key, axis, key == divider ? fraction : old,
                first.resizing(divider, fraction: fraction), second.resizing(divider, fraction: fraction))
        }
    }

    struct Divider: Identifiable {
        let id: UUID
        let direction: Direction
        let bounds: CGRect
        let frame: CGRect
        let fraction: Double
    }

    func geometry(in bounds: CGRect, paneHeight: CGFloat = 100) -> (panes: [UInt64: CGRect], dividers: [Divider]) {
        switch self {
        case .pane(let id): return ([id: bounds], [])
        case .branch(let key, let direction, let fraction, let first, let second):
            let horizontal = direction == .right
            let length = horizontal ? bounds.width : bounds.height
            let gap = min(BentoLayout.gutter, length)
            let usable = max(0, length - gap)
            let firstMinimum = horizontal ? 180 : first.minimumHeight(paneHeight: paneHeight)
            let secondMinimum = horizontal ? 180 : second.minimumHeight(paneHeight: paneHeight)
            let fit = min(1, usable / (firstMinimum + secondMinimum))
            let position = min(max(firstMinimum * fit, usable * fraction), usable - secondMinimum * fit)
            var leading = bounds
            var trailing = bounds
            var divider = bounds
            if horizontal {
                leading.size.width = position
                trailing.origin.x += position + gap
                trailing.size.width = usable - position
                divider.origin.x += position
                divider.size.width = gap
            } else {
                leading.size.height = position
                trailing.origin.y += position + gap
                trailing.size.height = usable - position
                divider.origin.y += position
                divider.size.height = gap
            }
            let left = first.geometry(in: leading, paneHeight: paneHeight)
            let right = second.geometry(in: trailing, paneHeight: paneHeight)
            return (
                left.panes.merging(right.panes) { value, _ in value },
                left.dividers + right.dividers + [
                    Divider(
                        id: key, direction: direction,
                        bounds: bounds, frame: divider, fraction: usable > 0 ? position / usable : 0.5)
                ]
            )
        }
    }
}
