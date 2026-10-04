import AppKit
import SwiftUI

/// A stable native scroll host keeps nested SwiftUI overlays accessible inside the workspace.
struct WorkspaceViewport<Content: View>: NSViewRepresentable {
    @Environment(CoreClient.self) private var client
    @Environment(WorkflowLayouts.self) private var layouts
    @Environment(FileTabsModel.self) private var tabs
    @Environment(TraceTerminalNavigation.self) private var navigation
    @Environment(HarnessModelCatalog.self) private var catalog
    @Environment(\.appZoom) private var zoom
    @Environment(\.traceLaneColors) private var laneColors
    let contentHeight: CGFloat
    @ViewBuilder let content: Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WorkspaceScrollView {
        let scroll = WorkspaceScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.setAccessibilityIdentifier("workspaceViewport")
        let hosting = NSHostingView(rootView: hostedContent)
        hosting.sizingOptions = []
        context.coordinator.hosting = hosting
        scroll.documentView = hosting
        scroll.documentHeight = contentHeight.rounded(.up)
        return scroll
    }

    func updateNSView(_ scroll: WorkspaceScrollView, context: Context) {
        context.coordinator.hosting?.rootView = hostedContent
        let height = contentHeight.rounded(.up)
        if scroll.documentHeight != height {
            scroll.documentHeight = height
            scroll.needsLayout = true
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WorkspaceScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    private var hostedContent: WorkspaceContent<Content> {
        WorkspaceContent(
            content: content, client: client, layouts: layouts, tabs: tabs,
            navigation: navigation, catalog: catalog, zoom: zoom, laneColors: laneColors)
    }

    final class Coordinator {
        var hosting: NSHostingView<WorkspaceContent<Content>>?
    }
}

struct WorkspaceContent<Content: View>: View {
    let content: Content
    let client: CoreClient
    let layouts: WorkflowLayouts
    let tabs: FileTabsModel
    let navigation: TraceTerminalNavigation
    let catalog: HarnessModelCatalog
    let zoom: AppZoom?
    let laneColors: [UInt64: Color]

    var body: some View {
        content
            .environment(client).environment(layouts).environment(tabs)
            .environment(navigation).environment(catalog)
            .environment(\.appZoom, zoom).environment(\.traceLaneColors, laneColors)
            .defaultAppStorage(WorkflowLaunchPreferences.defaultStore())
    }
}

final class WorkspaceScrollView: NSScrollView {
    var documentHeight: CGFloat = 0

    override func layout() {
        super.layout()
        let frame = NSRect(x: 0, y: 0, width: contentSize.width, height: documentHeight)
        let resized = documentView?.frame != frame
        if resized { documentView?.frame = frame }
        let origin = contentView.constrainBoundsRect(contentView.bounds).origin
        let moved = origin != contentView.bounds.origin
        if moved { contentView.scroll(to: origin) }
        if resized || moved { reflectScrolledClipView(contentView) }
    }
}
