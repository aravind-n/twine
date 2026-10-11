import SwiftUI

struct TerminalSplitDivider: View {
    let divider: TerminalSplit.Divider
    let resize: (Double) -> Void

    var body: some View {
        let horizontal = divider.direction == .right
        let length = max(1, (horizontal ? divider.bounds.width : divider.bounds.height) - BentoLayout.gutter)
        let minimum = min(0.5, (horizontal ? 180 : 100) / length)
        PaneDivider(
            axis: horizontal ? .horizontal : .vertical,
            fraction: divider.fraction, sharedLength: length,
            drag: { resize(min(1 - minimum, max(minimum, $0))) },
            save: { resize(min(1 - minimum, max(minimum, $0))) }
        )
        .accessibilityLabel("Resize terminal split")
    }
}
