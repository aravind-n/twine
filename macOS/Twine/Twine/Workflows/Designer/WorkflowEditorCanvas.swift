import SwiftUI

/// Native two-axis pan surrounds a graph in its own stable coordinate space.
struct WorkflowEditorCanvas: View {
    @Bindable var model: WorkflowDesignerModel
    @Binding var zoom: Double
    @Binding var connecting: String?
    @Binding var selection: WorkflowGraphSelection?
    let fitGraph: () -> Void
    @State private var selectedNodeID: String?
    @FocusState private var canvasFocused: Bool
    @State private var moving: String?
    @State private var translation = CGSize.zero
    @State private var pointer: CGPoint?
    @State private var connectingFromInput = false
    @State private var contextPoint = CGPoint.zero
    @State private var visibleRect = CGRect.zero
    @State private var showsSettings = false

    private var nodes: [String] { model.definition.roles.map(\.id) }
    private var size: CGSize { WorkflowEditorLayout.canvasSize(for: model.definition) }
    private var offset: CGSize { WorkflowEditorLayout.originOffset(for: model.definition) }

    var body: some View {
        GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                graph
                    .frame(width: size.width, height: size.height)
                    .coordinateSpace(name: "workflowCanvas")
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: size.width * zoom, height: size.height * zoom, alignment: .topLeading)
                    .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
                    .background { canvasBackground }
            }
            .defaultScrollAnchor(.topLeading, for: .sizeChanges)
            .onScrollGeometryChange(for: CGRect.self) {
                $0.visibleRect
            } action: { _, rect in
                visibleRect = rect
            }
            .overlay {
                if model.definition.roles.isEmpty {
                    WorkflowFirstRoleAction {
                        let rect = visibleRect.isEmpty ? CGRect(origin: .zero, size: viewport.size) : visibleRect
                        addAgent(at: CGPoint(x: rect.midX, y: rect.midY))
                    }
                }
            }
        }
        .background(WorkflowEditorStyle.canvas)
        .focusable(interactions: .edit)
        .focused($canvasFocused)
        .focusEffectDisabled()
        .onDeleteCommand { deleteSelectedNode() }
        .onExitCommand { cancelConnection() }
        .onChange(of: selection) { _, selection in
            if let selection {
                showsSettings = false
                cancelConnection()
                if case .node(let id) = selection {
                    selectedNodeID = id
                } else {
                    selectedNodeID = nil
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("designerContent")
    }

    private var canvasBackground: some View {
        Color.clear.contentShape(.rect)
            .gesture(
                SpatialTapGesture(count: 2).exclusively(before: SpatialTapGesture()).onEnded { gesture in
                    switch gesture {
                    case .first(let tap): addAgent(at: tap.location)
                    case .second: clearSelection()
                    }
                }
            )
            .contextMenu {
                Button("Add agent", systemImage: "plus") { addAgent(at: contextPoint) }
                    .accessibilityIdentifier("designerAddRole")
                Button("Workflow settings", systemImage: "slider.horizontal.3") {
                    clearSelection()
                    showsSettings = true
                }
                Divider()
                Button("Fit graph", action: fitGraph)
                Button("Actual size") { zoom = 1 }
                Button("Zoom in") { zoom = min(2, zoom + 0.1) }.disabled(zoom >= 2)
                Button("Zoom out") { zoom = max(0.25, zoom - 0.1) }.disabled(zoom <= 0.25)
            }
            .background { WorkflowCanvasGrid(zoom: zoom) }
            .background { WorkflowCanvasContextLocation { contextPoint = $0 } }
            .overlay(alignment: .topLeading) {
                Color.clear.frame(width: 1, height: 1)
                    .popover(isPresented: $showsSettings) { WorkflowGraphSettingsPopover(model: model).appZoom() }
                    .position(contextPoint)
            }
    }

    private func clearSelection() {
        selectedNodeID = nil
        selection = nil
        cancelConnection()
        canvasFocused = true
    }

    private func addAgent(at location: CGPoint) {
        clearSelection()
        showsSettings = false
        let position = CoreWorkflowType.Position(
            x: Int(min(4000, max(0, location.x / zoom - offset.width))),
            y: Int(min(4000, max(0, location.y / zoom - offset.height))))
        selection = .node(model.addGraphRole(at: position))
    }

    private var graph: some View {
        ZStack(alignment: .topLeading) {
            WorkflowGraphConnections(
                model: model, selection: $selection, source: connecting, pointer: pointer,
                target: connectionTarget, startsAtInput: connectingFromInput, point: point
            )
            .frame(width: size.width, height: size.height)
            ForEach(nodes, id: \.self) { id in
                node(id).position(point(id))
            }
            if connecting != nil, let pointer, connectionTarget == nil {
                Image(systemName: "circle.slash").font(.body).foregroundStyle(.secondary)
                    .position(x: pointer.x + 18, y: pointer.y + 18)
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
        }
    }

    private func point(_ id: String) -> CGPoint {
        let position =
            model.definition.graph?.positions[id]
            ?? WorkflowEditorLayout.defaultPosition(for: id, roles: model.definition.roles)
        return CGPoint(
            x: CGFloat(position.x) + offset.width + (moving == id ? translation.width : 0),
            y: CGFloat(position.y) + offset.height + (moving == id ? translation.height : 0))
    }

    private func node(_ id: String) -> some View {
        let role = model.definition.roles.first { $0.id == id }
        let graph = model.definition.graph
        return Button {
            if connecting != nil {
                completeConnection(with: id)
            } else {
                selectedNodeID = id
                canvasFocused = true
                selection = .node(id)
            }
        } label: {
            WorkflowGraphCard(
                title: role?.name ?? "Agent",
                emphasized: connecting == id || selectedNodeID == id || connectionTarget == id,
                tint: role?.color?.tint,
                startsHere: graph?.startsAgent(id) == true,
                returnsResult: graph?.returnsResult(id) == true,
                reviewsWork: graph?.reviewsWork(id) == true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("graphNode-\(id)")
        .accessibilityAddTraits(selectedNodeID == id ? .isSelected : [])
        .frame(width: WorkflowEditorLayout.cardSize.width, height: WorkflowEditorLayout.cardSize.height)
        .highPriorityGesture(moveNodeGesture(id))
        .overlay(alignment: .leading) {
            connector(id, output: false).offset(x: -WorkflowEditorLayout.portHitSize / 2)
        }
        .overlay(alignment: .trailing) {
            connector(id, output: true).offset(x: WorkflowEditorLayout.portHitSize / 2)
        }
        .popover(isPresented: nodePresentation(id)) {
            nodeEditor(id, role: role).onExitCommand(perform: closeNodeEditor)
        }
        .contextMenu {
            Button("Edit settings") { selection = .node(id) }
            WorkflowGraphConnectionMenu(model: model, source: id) { cancelConnection() }
            Button("Duplicate agent", systemImage: "plus.square.on.square") {
                clearSelection()
                if let copy = model.duplicateGraphAgent(id) { selectedNodeID = copy }
            }
            Divider()
            Button("Delete agent", role: .destructive) {
                clearSelection()
                model.removeGraphRole(id)
            }
        }

    }

    @ViewBuilder
    private func nodeEditor(_ id: String, role: CoreWorkflowType.Role?) -> some View {
        if let role {
            WorkflowGraphAgentPopover(model: model, role: role, close: closeNodeEditor).appZoom()
        }
    }

    private func connector(_ id: String, output: Bool) -> some View {
        let role = model.definition.roles.first { $0.id == id }
        let name = role?.name ?? id.capitalized
        return Button {
            if connecting != nil, output == connectingFromInput {
                completeConnection(with: id)
            } else {
                connecting = id
                connectingFromInput = !output
                pointer = nil
            }
        } label: {
            Circle().fill(WorkflowEditorStyle.card)
                .overlay {
                    Circle().stroke(
                        connecting == id || connectionTarget == id
                            ? Color.accentColor : (role?.color?.tint ?? .secondary).opacity(0.7), lineWidth: 1.5)
                }
                .frame(width: 10, height: 10)
        }
        .buttonStyle(.plain)
        .frame(width: WorkflowEditorLayout.portHitSize, height: WorkflowEditorLayout.portHitSize)
        .contentShape(.rect)
        .help(output ? "Connect to another agent" : "Connect work from another agent")
        .accessibilityLabel(output ? "Connect from \(name)" : "Connect to \(name)")
        .accessibilityIdentifier("graphPort-\(id)-\(output ? "out" : "in")")
        .highPriorityGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("workflowCanvas")).onChanged { value in
                connecting = id
                connectingFromInput = !output
                let origin = point(id)
                let portOffset = WorkflowEditorLayout.cardSize.width / 2 * (output ? 1 : -1)
                pointer = CGPoint(
                    x: origin.x + portOffset + value.translation.width,
                    y: origin.y + value.translation.height)
            }.onEnded { _ in
                if let target = connectionTarget {
                    completeConnection(with: target)
                } else {
                    cancelConnection()
                }
            })
    }

    private var connectionTarget: String? {
        guard let pointer, connecting != nil else { return nil }
        return nodes.first { candidate in
            guard let endpoints = connectionEndpoints(with: candidate),
                model.canConnect(from: endpoints.source, to: endpoints.destination)
            else { return false }
            let portOffset = WorkflowEditorLayout.cardSize.width / 2 * (connectingFromInput ? 1 : -1)
            let target = point(candidate)
            return abs(target.x + portOffset - pointer.x) <= WorkflowEditorLayout.portHitSize / 2
                && abs(target.y - pointer.y) <= WorkflowEditorLayout.portHitSize / 2
        }
    }

}

extension WorkflowEditorCanvas {
    private func moveNodeGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("workflowCanvas")).onChanged { value in
            guard pointer == nil else { return }
            selectedNodeID = id
            canvasFocused = true
            moving = id
            translation = value.translation
        }.onEnded { _ in
            guard moving == id else { return }
            let destination = point(id)
            let savedPosition = CoreWorkflowType.Position(
                x: Int(min(4000, max(0, destination.x - offset.width))),
                y: Int(min(4000, max(0, destination.y - offset.height))))
            model.definition.graph?.positions[id] = savedPosition
            moving = nil
            translation = .zero
        }
    }

    private func connectionEndpoints(with candidate: String) -> (source: String, destination: String)? {
        guard let origin = connecting else { return nil }
        return connectingFromInput ? (candidate, origin) : (origin, candidate)
    }

    private func completeConnection(with candidate: String) {
        guard let endpoints = connectionEndpoints(with: candidate),
            model.canConnect(from: endpoints.source, to: endpoints.destination)
        else { return }
        model.connect(from: endpoints.source, to: endpoints.destination)
        cancelConnection()
    }

    private func closeNodeEditor() {
        selection = nil
        canvasFocused = true
    }

    private func deleteSelectedNode() {
        guard canvasFocused, selection == nil, let id = selectedNodeID,
            model.definition.roles.contains(where: { $0.id == id })
        else { return }
        selectedNodeID = nil
        cancelConnection()
        model.removeGraphRole(id)
    }

    private func cancelConnection() {
        connecting = nil
        connectingFromInput = false
        pointer = nil
    }

    private func nodePresentation(_ id: String) -> Binding<Bool> {
        Binding(get: { selection == .node(id) }, set: { if !$0 && selection == .node(id) { selection = nil } })
    }
}
