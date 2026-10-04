import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var appZoom: AppZoom?
    @Entry var appZoomMaximumPresentationSize = CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
}

extension View {
    /// Apply once at each presentation root. Descendants keep their normal design coordinates,
    /// including native views and drawing/hit testing in canvases, rulers, and minimaps.
    func appZoom() -> some View { modifier(AppZoomModifier()) }
}

private struct AppZoomModifier: ViewModifier {
    @Environment(\.appZoom) private var zoom
    @State private var screenSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 720)

    func body(content: Content) -> some View {
        let scale = zoom?.scale ?? 1
        // Reserve physical space for native presentation chrome, then convert to design points.
        let maximum = CGSize(
            width: max(0, screenSize.width - 80) / scale, height: max(0, screenSize.height - 80) / scale)
        AppZoomLayout(scale: scale) {
            content.environment(\.appZoomMaximumPresentationSize, maximum).scaleEffect(scale, anchor: .topLeading)
        }
        .background {
            PresentationScreen { screenSize = $0 }.frame(width: 0, height: 0)
        }
    }
}

/// Adjust the layout proposal as well as the drawing scale, so zooming reflows content within
/// the current window instead of drawing a larger interface outside its edges.
nonisolated struct AppZoomLayout: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(
            ProposedViewSize(width: proposal.width.map { $0 / scale }, height: proposal.height.map { $0 / scale }))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for content in subviews {
            content.place(
                at: bounds.origin, anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width / scale, height: bounds.height / scale))
        }
    }
}

#Preview {
    @Previewable @State var zoom = AppZoom()
    VStack {
        Text("Interface zoom").font(.title)
        HStack {
            Button("Zoom Out", action: zoom.zoomOut)
            Button("Actual Size", action: zoom.reset)
            Button("Zoom In", action: zoom.zoomIn)
        }
    }
    .padding().appZoom().environment(\.appZoom, zoom)
}
