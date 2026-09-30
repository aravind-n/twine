import Foundation

/// Keeps a selectable part of the timeline visible beside the event log.
nonisolated struct TracePanelLayout {
    let detailWidth: CGFloat
    let labelWidth: CGFloat
    let timelineViewportWidth: CGFloat

    init(width: CGFloat, showsDetails: Bool) {
        let width = max(0, width)
        if showsDetails {
            let normalTimeline =
                TracesLayout.detailLabelWidth + TracesLayout.timelineTrailingInset
                + TracesLayout.timelineMinimumViewport
            if width >= normalTimeline + TracesLayout.detailMinimumWidth {
                detailWidth = min(TracesLayout.detailMaximumWidth, max(TracesLayout.detailMinimumWidth, width * 0.4))
                labelWidth = TracesLayout.detailLabelWidth
            } else {
                detailWidth = width * 0.6
                labelWidth = TracesLayout.compactLabelWidth
            }
        } else {
            detailWidth = 0
            labelWidth = TracesLayout.labelWidth
        }
        timelineViewportWidth = max(0, width - detailWidth - labelWidth - TracesLayout.timelineTrailingInset)
    }
}
