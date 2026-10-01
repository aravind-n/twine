import SwiftUI

struct TerminalMinimap: View {
    @Environment(\.traceLaneColors) private var laneColors
    let state: TerminalMinimapState
    let markers: [TraceMinimapMarker]
    let selectedID: UInt64?
    let select: (UInt64) -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    @State private var dragOffset: CGFloat?
    private var isExpanded: Bool { isHovered || isFocused || dragOffset != nil }

    var body: some View {
        GeometryReader { geometry in
            let height = state.geometry.contentHeight(available: geometry.size.height)
            rail(height: height)
                .frame(width: isExpanded ? 92 : 14, height: height)
                .frame(width: 14, alignment: .trailing)
        }
        .frame(width: 14)
        .onHover { isHovered = $0 }
        .onKeyPress(.upArrow) {
            state.scroll(to: state.geometry.topRow - 3)
            return .handled
        }
        .onKeyPress(.downArrow) {
            state.scroll(to: state.geometry.topRow + 3)
            return .handled
        }
        .onKeyPress(.home) {
            state.scroll(to: 0)
            return .handled
        }
        .onKeyPress(.end) {
            state.returnToLive()
            return .handled
        }
        .onKeyPress(.pageUp) {
            state.scroll(to: state.geometry.topRow - state.geometry.visibleRows)
            return .handled
        }
        .onKeyPress(.pageDown) {
            state.scroll(to: state.geometry.topRow + state.geometry.visibleRows)
            return .handled
        }
        .onKeyPress(.escape) {
            isFocused = false
            state.view?.window?.makeFirstResponder(state.view)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal minimap")
        .accessibilityIdentifier("terminalMinimap")
        .help(state.failureMessage ?? "Drag to scroll. Trace points match the steps below. Home / End to jump.")
    }

    private func rail(height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(.terminalBackground)
                .accessibilityHidden(true)
            Canvas { context, size in
                for (index, stroke) in state.strokes.enumerated() {
                    let rect = TerminalMinimapGeometry.strokeRect(stroke, in: size, expanded: isExpanded)
                    let ink =
                        state.strokeColors.indices.contains(index) ? state.strokeColors[index] : .terminalTextMuted
                    context.fill(Path(rect), with: .color(ink.opacity(isExpanded ? 0.65 : 0.18)))
                }
                let range = state.geometry.viewport
                let top = range.lowerBound * size.height
                let thumb = CGRect(
                    x: 0, y: top, width: size.width, height: max(8, (range.upperBound - range.lowerBound) * size.height)
                )
                context.fill(Path(roundedRect: thumb, cornerRadius: 3), with: .color(.terminalTextMuted.opacity(0.12)))
                if isExpanded {
                    context.stroke(
                        Path(roundedRect: thumb, cornerRadius: 3), with: .color(.terminalTextMuted.opacity(0.45)))
                }
            }
            .contentShape(Rectangle())
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .accessibilityLabel("Scroll terminal output")
            .accessibilityValue(state.geometry.isLive ? "Latest output" : "Line \(state.geometry.topRow + 1)")
            .accessibilityAdjustableAction { direction in
                state.scroll(to: state.geometry.topRow + (direction == .increment ? 3 : -3))
            }
            .gesture(scrollGesture(height: height))
            ForEach(markers) { marker in
                if let row = state.markerRows[marker.id] {
                    point(marker)
                        .offset(y: max(0, min(height - 10, Double(row) / Double(state.geometry.rows) * height - 5)))
                }
            }
        }
        .clipShape(.rect(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(isExpanded ? 0.08 : 0.03)))
        .shadow(color: .black.opacity(isExpanded ? 0.08 : 0), radius: 10, x: -5)
    }

    private func scrollGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            if dragOffset == nil {
                let range = state.geometry.viewport
                let top = range.lowerBound * height
                let bottom = range.upperBound * height
                dragOffset =
                    value.startLocation.y >= top && value.startLocation.y <= bottom
                    ? value.startLocation.y - top : (bottom - top) / 2
            }
            let fraction = (value.location.y - (dragOffset ?? 0)) / max(1, height)
            state.scroll(to: Int((fraction * Double(state.geometry.rows)).rounded()))
        }.onEnded { _ in dragOffset = nil }
    }

    private func point(_ marker: TraceMinimapMarker) -> some View {
        Button {
            select(marker.id)
        } label: {
            HStack(spacing: 3) {
                if isExpanded { Text(marker.step.number).font(.system(size: 8, design: .monospaced)) }
                Spacer(minLength: 0)
                Circle().fill(
                    marker.step.span.status == .failed
                        ? Color.orange : TraceLaneStyle.color(for: marker.lane, colors: laneColors)
                )
                .frame(width: 5, height: 5)
                .overlay { if marker.id == selectedID { Circle().stroke(.primary, lineWidth: 1).padding(-2) } }
            }
            .padding(.horizontal, 4).frame(height: 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: 10)
        .help("\(marker.title) · \(marker.lane.name)")
        .accessibilityLabel("Trace \(marker.title), \(marker.lane.name)")
        .accessibilityIdentifier("minimapStep-\(marker.id)")
    }
}

#Preview {
    @Previewable @State var selectedID: UInt64?
    TerminalMinimap(state: TerminalMinimapState(), markers: [], selectedID: selectedID) { selectedID = $0 }
        .frame(height: 350).padding(100).background(.terminalBackground)
}
