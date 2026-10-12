import SwiftUI

nonisolated enum TracesLayout {
    static let collapsedHeight: CGFloat = 28
    static let expandedHeaderHeight: CGFloat = 48
    static let expandedHeight: CGFloat = expandedHeaderHeight + 224
    static let detailHeaderHeight: CGFloat = 48
    static let axisHeight: CGFloat = 14
    static let laneHeight: CGFloat = 18
    static let labelWidth: CGFloat = 126
    static let detailLabelWidth: CGFloat = 104
    static let compactLabelWidth: CGFloat = 36
    static let timelineMinimumViewport: CGFloat = 100
    static let timelineTrailingInset: CGFloat = 14
    static let focusHeaderHeight: CGFloat = 24
    /// Room for the 10-point tick, lane, and duration labels within the focus cards.
    static let focusRailHeight: CGFloat = 112
    static let hintHeight: CGFloat = 28
    static let detailMinimumWidth: CGFloat = 280
    static let detailMaximumWidth: CGFloat = 440
    static let headerHorizontalPadding: CGFloat = 12
    static let expandedHeaderHorizontalPadding: CGFloat = 21
    static let chevronSize: CGFloat = 28
    static let expandedChevronSize: CGFloat = 26
}
