import SwiftUI

/// One interpolated height keeps the terminal viewport and Traces disclosure adjacent.
nonisolated struct WorkspacePaneLayout: Layout {
    var revealProgress: CGFloat
    let traceBodyHeight: CGFloat
    let traceHeaderHeight: CGFloat
    let traceHeaderExpansion: CGFloat
    let footerHeight: CGFloat
    let spacing: CGFloat
    let showsTraces: Bool

    var animatableData: CGFloat {
        get { revealProgress }
        set { revealProgress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == (showsTraces ? 3 : 2), let workflow = subviews.first, let footer = subviews.last else {
            return
        }
        let traceHeight =
            showsTraces
            ? traceHeaderHeight + (traceHeaderExpansion + traceBodyHeight) * min(1, max(0, revealProgress)) : 0
        let gaps = spacing * (showsTraces ? 2 : 1)
        let workflowHeight = max(0, bounds.height - footerHeight - gaps - traceHeight)
        workflow.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: workflowHeight))
        var nextY = bounds.minY + workflowHeight + spacing
        if showsTraces {
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: nextY), anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: traceHeight))
            nextY += traceHeight + spacing
        }
        footer.place(
            at: CGPoint(x: bounds.minX, y: nextY), anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: footerHeight))
    }
}
