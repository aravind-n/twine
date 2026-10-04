import SwiftUI

/// The gutter between two panes, which drags to resize them.
struct PaneDivider: View {
    @Environment(\.appZoom) private var zoom
    /// The direction the divider moves in.
    let axis: Axis
    let fraction: Double
    /// The length the two panes share, which a drag's translation is a fraction of.
    let sharedLength: CGFloat
    /// Shows a fraction while the divider is dragged, without saving it.
    let drag: (Double) -> Void
    /// Saves a fraction, when a drag ends or an accessibility action adjusts the divider.
    let save: (Double) -> Void
    @State private var dragStart: Double?

    var body: some View {
        Color.clear
            .contentShape(.rect)
            .pointerStyle(axis == .horizontal ? .columnResize : .rowResize)
            .gesture(
                // In window coordinates: the divider moves as it's dragged, so its own would shift under the pointer.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag(fraction(after: $0)) }
                    .onEnded { value in
                        save(fraction(after: value))
                        dragStart = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(axis == .horizontal ? "Column divider" : "Row divider")
            .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: save(fraction + 0.05)
                case .decrement: save(fraction - 0.05)
                @unknown default: break
                }
            }
            .accessibilityIdentifier(axis == .horizontal ? "columnDivider" : "rowDivider")
    }

    /// Where a drag has moved the divider, from where the drag started.
    private func fraction(after drag: DragGesture.Value) -> Double {
        let start = dragStart ?? fraction
        dragStart = start
        let translation = axis == .horizontal ? drag.translation.width : drag.translation.height
        return Self.fraction(
            start: start, translation: translation, sharedLength: sharedLength, scale: zoom?.scale ?? 1)
    }

    nonisolated static func fraction(
        start: Double, translation: CGFloat, sharedLength: CGFloat, scale: CGFloat
    ) -> Double {
        sharedLength > 0 ? start + translation / scale / sharedLength : start
    }
}

#Preview {
    PaneDivider(
        axis: .horizontal, fraction: 0.5, sharedLength: 400,
        drag: { _ in NSSound.beep() }, save: { _ in NSSound.beep() }
    )
    .frame(width: 10, height: 200)
}
