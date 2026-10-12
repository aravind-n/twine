import SwiftUI

nonisolated enum NewTabLayout {
    static let maximumWidth: CGFloat = 740
    /// Leave the terminal's first row visible when the choices need to scroll.
    static let promptClearance: CGFloat = 2 * Spacing.terminalContent
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 14
    static let headingSpacing: CGFloat = 10
    static let choiceTextSpacing: CGFloat = 4
    static let minimumChoiceWidth: CGFloat = 160
    static let minimumChoiceHeight: CGFloat = 64
    /// Keep the heading and first choice row visible together in the scrollable card.
    static let minimumChoiceViewportHeight: CGFloat = 2 * minimumChoiceHeight
    static let choicePadding: CGFloat = 10
    static let symbolWidth: CGFloat = 16
    /// The close button's inset from the card's top trailing corner.
    static let closePadding: CGFloat = 8
}
