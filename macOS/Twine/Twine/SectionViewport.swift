import SwiftUI

/// Keep section contents at full size while their visible layout height opens or closes.
nonisolated struct SectionViewport<Content: View>: View, Animatable {
    let isExpanded: Bool
    let height: CGFloat
    let alignment: Alignment
    let content: Content
    private var visibleHeight: CGFloat

    init(isExpanded: Bool, height: CGFloat, alignment: Alignment = .top, @ViewBuilder content: () -> Content) {
        self.isExpanded = isExpanded
        self.height = height
        self.alignment = alignment
        self.content = content()
        visibleHeight = isExpanded ? height : 0
    }

    var animatableData: CGFloat {
        get { visibleHeight }
        set { visibleHeight = newValue }
    }

    var body: some View {
        content
            .frame(height: height, alignment: alignment)
            .animation(nil, value: height)
            .animation(nil, value: isExpanded)
            .frame(height: max(0, visibleHeight), alignment: alignment)
            .clipped()
            .geometryGroup()
            .disabled(visibleHeight <= 0)
            .allowsHitTesting(isExpanded && visibleHeight > 0)
            .accessibilityHidden(!isExpanded || visibleHeight <= 0)
    }
}
