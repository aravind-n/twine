import SwiftUI

/// Where an agents workflow's panes go in a panel of a given size. In Bento mode, columns hold one
/// or two panes: two panes sit side by side, three put one beside two stacked, and four make a grid.
/// A panel too small for that shows fewer panes, always keeping the focused one. A single pane, like
/// tab mode's one agent, fills the panel.
nonisolated struct PaneArrangement: Equatable {
    struct Column: Equatable {
        /// The column's place among all the panes' columns, which picks its row fraction.
        let index: Int
        /// The agents in the column's panes, top to bottom.
        let agentIDs: [UInt64]
    }

    enum Slot: Hashable {
        case agent(UInt64)
        case columnDivider
        /// The divider between the two panes of the column with this index.
        case rowDivider(Int)
    }

    let columns: [Column]

    /// Tab mode: the focused agent alone.
    init(focusedAgentID: UInt64?) {
        columns = focusedAgentID.map { [Column(index: 0, agentIDs: [$0])] } ?? []
    }

    /// Bento mode: the panes, fewer when `size` can't fit them at their minimum size.
    init(panes: [UInt64], focusedAgentID: UInt64, size: CGSize) {
        let groups: [[UInt64]] =
            switch panes.count {
            case 0: []
            case 1: [panes]
            case 2: [[panes[0]], [panes[1]]]
            case 3: [[panes[0]], [panes[1], panes[2]]]
            default: [[panes[0], panes[1]], [panes[2], panes[3]]]
            }
        var columns = groups.enumerated().map { Column(index: $0.offset, agentIDs: $0.element) }
        let minimum = BentoLayout.minimumPaneSize
        if Self.sharedLength(size.width) < 2 * minimum.width, let first = columns.first {
            columns = [columns.first { $0.agentIDs.contains(focusedAgentID) } ?? first]
        }
        if Self.sharedLength(size.height) < 2 * minimum.height {
            columns = columns.map { column in
                let agentID = column.agentIDs.contains(focusedAgentID) ? focusedAgentID : column.agentIDs[0]
                return Column(index: column.index, agentIDs: [agentID])
            }
        }
        self.columns = columns
    }

    var visibleAgentIDs: [UInt64] { columns.flatMap(\.agentIDs) }

    /// Whether panes show side by side, as rounded panes with headers, instead of one filling the panel.
    var isTiled: Bool { visibleAgentIDs.count > 1 }

    /// The frames of the visible panes and of the dividers between them.
    func frames(in bounds: CGRect, columnFraction: Double, rowFractions: [Double]) -> [Slot: CGRect] {
        guard isTiled else {
            return Dictionary(uniqueKeysWithValues: visibleAgentIDs.map { (Slot.agent($0), bounds) })
        }
        let gutter = BentoLayout.gutter
        // Not `insetBy`, whose null rectangle for bounds smaller than the gutters would place views at infinity.
        let content = CGRect(
            x: bounds.minX + gutter, y: bounds.minY + gutter,
            width: max(0, bounds.width - 2 * gutter), height: max(0, bounds.height - 2 * gutter))
        let minimum = BentoLayout.minimumPaneSize
        var frames: [Slot: CGRect] = [:]
        var columnFrames = [content]
        if columns.count > 1 {
            let (leading, trailing) = content.divided(
                atDistance: Self.leadingLength(of: bounds.width, fraction: columnFraction, minimum: minimum.width),
                from: .minXEdge)
            columnFrames = [leading, trailing.inset(by: gutter, from: .minXEdge)]
            frames[.columnDivider] = CGRect(
                x: leading.maxX + (gutter - BentoLayout.dividerThickness) / 2, y: content.minY,
                width: BentoLayout.dividerThickness, height: content.height)
        }
        for (column, frame) in zip(columns, columnFrames) {
            guard column.agentIDs.count > 1 else {
                frames[.agent(column.agentIDs[0])] = frame
                continue
            }
            let fraction = rowFractions.indices.contains(column.index) ? rowFractions[column.index] : 0.5
            let (top, bottom) = frame.divided(
                atDistance: Self.leadingLength(of: bounds.height, fraction: fraction, minimum: minimum.height),
                from: .minYEdge)
            frames[.agent(column.agentIDs[0])] = top
            frames[.agent(column.agentIDs[1])] = bottom.inset(by: gutter, from: .minYEdge)
            frames[.rowDivider(column.index)] = CGRect(
                x: frame.minX, y: top.maxY + (gutter - BentoLayout.dividerThickness) / 2,
                width: frame.width, height: BentoLayout.dividerThickness)
        }
        return frames
    }

    /// The length two panes share along a panel's side, after the gutters around and between them.
    static func sharedLength(_ panelLength: CGFloat) -> CGFloat {
        max(0, panelLength - 3 * BentoLayout.gutter)
    }

    /// A split fraction limited so that each pane keeps at least `minimum` of the shared length when
    /// there's room. Saved fractions pass through this too, so a smaller window can't squeeze a pane.
    static func clampedFraction(_ fraction: Double, panelLength: CGFloat, minimum: CGFloat) -> Double {
        let shared = sharedLength(panelLength)
        guard shared > 0, fraction.isFinite else { return 0.5 }
        let limit = min(0.5, minimum / shared)
        return min(max(fraction, limit), 1 - limit)
    }

    private static func leadingLength(of panelLength: CGFloat, fraction: Double, minimum: CGFloat) -> CGFloat {
        sharedLength(panelLength) * clampedFraction(fraction, panelLength: panelLength, minimum: minimum)
    }
}

extension CGRect {
    nonisolated fileprivate func inset(by amount: CGFloat, from edge: CGRectEdge) -> CGRect {
        divided(atDistance: amount, from: edge).remainder
    }
}

/// Places each agent's terminal and each divider in its arrangement frame. Agents without a visible
/// pane fill the panel behind the panes, hidden, so their terminals keep a usable size.
nonisolated struct PaneLayout: Layout {
    let arrangement: PaneArrangement
    let columnFraction: Double
    let rowFractions: [Double]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrangement.frames(in: bounds, columnFraction: columnFraction, rowFractions: rowFractions)
        for subview in subviews {
            guard let slot = subview[PaneSlot.self] else { continue }
            let fallback = if case .agent = slot { bounds } else { CGRect(origin: bounds.origin, size: .zero) }
            let frame = frames[slot] ?? fallback
            subview.place(at: frame.origin, proposal: ProposedViewSize(frame.size))
        }
    }
}

nonisolated struct PaneSlot: LayoutValueKey {
    static let defaultValue: PaneArrangement.Slot? = nil
}
