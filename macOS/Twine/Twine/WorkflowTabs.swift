import SwiftUI

struct WorkflowTabs: View {
    @Environment(FileTabsModel.self) private var fileTabs
    let workflows: [CoreWorkflow]
    let selectedID: UInt64?
    let select: (UInt64) -> Void
    let close: (UInt64) -> Void
    let cancelAgent: (UInt64) -> Void
    let create: () -> Void
    @State private var tabsWidth: CGFloat?

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            Text("WORKFLOWS")
                .sectionLabelStyle()
                .fixedSize()
                .padding(.bottom, 11)
            scrollingTabs
                .frame(maxWidth: tabsWidth)
                .layoutPriority(1)
            createButton
            Spacer(minLength: 0)
        }
        .frame(height: 42, alignment: .bottom)
    }

    private var tabs: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(workflows) { workflow in
                WorkspaceTab(
                    name: workflow.name, symbol: workflow.tabSymbol,
                    tabID: "workflowTab-\(workflow.id)", closeID: "closeWorkflow-\(workflow.id)",
                    helpText: workflow.name,
                    fill: workflow.showsTerminalStrip ? .workflowTint : .terminalBackground,
                    isSelected: workflow.id == selectedID,
                    select: { select(workflow.id) },
                    close: { close(workflow.id) }
                )
                .contextMenu {
                    if workflow.isRunningAgent {
                        Button("Cancel Agent", systemImage: "stop.circle") { cancelAgent(workflow.id) }
                    }
                    Button("Close Workflow", systemImage: "xmark") { close(workflow.id) }
                }
                .id(workflow.id)
            }
            ForEach(fileTabs.editors) { editor in
                WorkspaceTab(
                    name: URL(filePath: editor.path).lastPathComponent, symbol: "doc.text",
                    tabID: "fileTab-\(editor.path)", closeID: "closeFile-\(editor.path)", helpText: editor.path,
                    fill: Color(nsColor: .textBackgroundColor), isEdited: editor.isDirty,
                    isSelected: editor.id == fileTabs.selectedID,
                    select: { fileTabs.select(editor.id) }, close: { fileTabs.close(editor.id) }
                )
                .contextMenu {
                    Button("Close File", systemImage: "xmark") { fileTabs.close(editor.id) }
                }
                .id(editor.id)
            }
        }
        .padding(.horizontal, 1)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { tabsWidth = $0 })
    }

    private var scrollingTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) { tabs }
                .scrollIndicators(.hidden)
                .onChange(of: selectedTabID) {
                    if let selectedTabID {
                        withAnimation(Motion.scrollToSelectedTab) { proxy.scrollTo(selectedTabID) }
                    }
                }
                .onChange(of: workflows.map(\.id)) {
                    if let selectedTabID {
                        withAnimation(Motion.scrollToSelectedTab) { proxy.scrollTo(selectedTabID) }
                    }
                }
                .onChange(of: fileTabs.editors.map(\.id)) {
                    if let selectedTabID {
                        withAnimation(Motion.scrollToSelectedTab) { proxy.scrollTo(selectedTabID) }
                    }
                }
                .onGeometryChange(
                    for: CGFloat.self, of: { $0.size.width },
                    action: { _ in
                        if let selectedTabID { proxy.scrollTo(selectedTabID) }
                    })
        }
    }

    private var selectedTabID: AnyHashable? {
        if let id = fileTabs.selectedID { return AnyHashable(id) }
        return selectedID.map { AnyHashable($0) }
    }

    private var createButton: some View {
        Button("New Workflow", systemImage: "plus", action: create)
            .labelStyle(.iconOnly)
            .font(.system(size: 11, weight: .semibold))
            .buttonStyle(.glass)
            .buttonBorderShape(.roundedRectangle(radius: CornerRadius.glassIconButton))
            .controlSize(.small)
            .frame(width: 26, height: 26)
            .padding(.bottom, 5)
            .help("New Workflow (⌘T)")
            .accessibilityIdentifier("newWorkflow")
    }
}

private struct WorkspaceTab: View {
    let name: String
    let symbol: String
    let tabID: String
    let closeID: String
    let helpText: String
    let fill: Color
    var isEdited = false
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovered = false
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable { case select, close }

    private var showsClose: Bool { isHovered || focusedControl != nil }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .frame(width: 15)
                    .opacity(showsClose ? 0 : 1)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180)
                if isEdited {
                    Circle().fill(.secondary).frame(width: 5, height: 5).accessibilityHidden(true)
                }
            }
            .tabTitleStyle(isSelected: isSelected)
            .padding(.horizontal, 12)
            .frame(height: isSelected ? 35 : 29)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: .select)
        .accessibilityLabel(name)
        .accessibilityValue(
            [isSelected ? "Selected" : nil, isEdited ? "Edited" : nil].compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityIdentifier(tabID)
        .background {
            if isSelected {
                tabShape.fill(fill)
                    .overlay {
                        tabShape.strokeBorder(.hairline, lineWidth: Surface.hairlineWidth)
                            .mask { Rectangle().padding(.bottom, Surface.hairlineWidth) }
                    }
            }
        }
        .overlay(alignment: .leading) {
            Button("Close \(name)", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 23)
                .buttonStyle(.plain)
                .focused($focusedControl, equals: .close)
                .padding(.leading, 9)
                .opacity(showsClose ? 1 : 0)
                .allowsHitTesting(showsClose)
                .accessibilityHidden(!showsClose)
                .accessibilityIdentifier(closeID)
        }
        .onHover { isHovered = $0 }
        .animation(Motion.tabCloseButton, value: showsClose)
        .help(helpText)
    }

    private var tabShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: CornerRadius.selectedTab, topTrailingRadius: CornerRadius.selectedTab)
    }
}
