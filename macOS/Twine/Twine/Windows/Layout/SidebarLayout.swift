import SwiftUI

nonisolated enum SidebarLayout {
    /// Keep section headers and memory controls reachable by scrolling in short windows.
    static let minimumContentHeight: CGFloat = 400
    static let minimumWidth: CGFloat = 245
    static let idealWidth: CGFloat = 285
    static let maximumWidth: CGFloat = 325
    static let contentInset: CGFloat = 10
    static let sectionHeaderHeight: CGFloat = 48
    static let sectionHeaderPadding: CGFloat = 17
    static let rowHeight: CGFloat = 27
    static let rowInset: CGFloat = 13
    static let rowFontSize: CGFloat = 12.5
}
