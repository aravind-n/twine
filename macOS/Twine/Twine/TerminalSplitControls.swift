import SwiftUI

struct TerminalSplitControls: View {
    let split: (TerminalSplit.Direction) -> Void
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button {
                split(.right)
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .help("Split Right (⌘D)")
            .accessibilityLabel("Split Right")
            .accessibilityIdentifier("splitTerminalRight")
            Button {
                split(.down)
            } label: {
                Image(systemName: "rectangle.split.1x2")
            }
            .help("Split Down (⇧⌘D)")
            .accessibilityLabel("Split Down")
            .accessibilityIdentifier("splitTerminalDown")
        }
        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
        .disabled(!isEnabled)
        .padding(.horizontal, 10).padding(.bottom, 10)
    }
}

struct TerminalSplitDivider: View {
    let divider: TerminalSplit.Divider
    let resize: (Double) -> Void
    @State private var initialFraction: Double?

    var body: some View {
        Color.clear
            .overlay {
                Rectangle().fill(.hairline)
                    .frame(width: divider.direction == .right ? 1 : nil, height: divider.direction == .down ? 1 : nil)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .global).onChanged { value in
                    if initialFraction == nil { initialFraction = divider.fraction }
                    let horizontal = divider.direction == .right
                    let length = (horizontal ? divider.bounds.width : divider.bounds.height) - 6
                    let movement = horizontal ? value.translation.width : value.translation.height
                    let minimum = min(0.5, (horizontal ? 180 : 100) / max(1, length))
                    resize(min(1 - minimum, max(minimum, (initialFraction ?? 0.5) + movement / max(1, length))))
                }.onEnded { _ in initialFraction = nil }
            )
            .onHover { hovering in
                if hovering {
                    (divider.direction == .right ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityLabel("Resize terminal split")
            .accessibilityAdjustableAction { direction in
                resize(min(0.85, max(0.15, divider.fraction + (direction == .increment ? 0.05 : -0.05))))
            }
    }
}

#Preview {
    TerminalSplitControls(split: { _ in NSSound.beep() }, isEnabled: true).padding()
}
