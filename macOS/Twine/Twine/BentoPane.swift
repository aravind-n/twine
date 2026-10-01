import SwiftUI

/// The same rounded terminal surface and keyboard focus ring for shells and agents.
private struct BentoPane: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive
    let isTiled: Bool
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .background(.terminalBackground)
            .clipShape(.rect(cornerRadius: isTiled ? CornerRadius.bentoPane : 0))
            .overlay {
                if isTiled {
                    RoundedRectangle(cornerRadius: CornerRadius.bentoPane)
                        .strokeBorder(
                            isFocused ? (appearsActive ? Color.paneFocus : .secondary) : .hairline,
                            lineWidth: isFocused ? BentoLayout.focusRingWidth : Surface.hairlineWidth
                        )
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func bentoPane(isTiled: Bool, isFocused: Bool) -> some View {
        modifier(BentoPane(isTiled: isTiled, isFocused: isFocused))
    }
}
