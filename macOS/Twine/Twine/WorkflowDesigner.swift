import SwiftUI

struct WorkflowDesigner: View {
    @Environment(CoreClient.self) private var client
    @Environment(\.undoManager) private var undoManager
    @State private var model: WorkflowDesignerModel
    @State private var zoom = 1.0
    @State private var viewport = CGSize.zero
    @State private var connecting: String?
    @State private var selection: WorkflowGraphSelection?
    @FocusState private var nameFocused: Bool
    let isSelected: Bool
    let saved: (CoreWorkflowType) -> Void
    let cancel: () -> Void

    init(
        type: CoreWorkflowType? = nil, isSelected: Bool = true, saved: @escaping (CoreWorkflowType) -> Void,
        cancel: @escaping () -> Void = {}
    ) {
        let model = WorkflowDesignerModel(type: type)
        model.enableGraph()
        _model = State(initialValue: model)
        self.isSelected = isSelected
        self.saved = saved
        self.cancel = cancel
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let notice = model.conversionNotice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 12)
                    .accessibilityIdentifier("designerConversionNotice")
            }
            Divider()
            WorkflowEditorCanvas(
                model: model, zoom: $zoom, connecting: $connecting, selection: $selection, fitGraph: fitGraph
            )
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: { size in
                let firstLayout = viewport == .zero
                viewport = size
                if firstLayout { fitGraph() }
            }
            Divider()
            footer
        }
        .background(WorkflowEditorStyle.canvas).disabled(model.isSaving)
        .task(id: model.definition) { await model.validate(using: client) }
        .onChange(of: model.definition) { previous, _ in model.recordUndo(from: previous, using: undoManager) }
        .onAppear { nameFocused = model.definition.name.isEmpty }
        .focusedSceneValue(\.saveAction, isSelected ? SaveAction(isEnabled: { model.canSave }, perform: save) : nil)
        .onDisappear { undoManager?.removeAllActions(withTarget: model) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflowDesigner")
    }

    private var header: some View {
        @Bindable var model = model
        return HStack(spacing: 16) {
            Button("Back", systemImage: "chevron.left", action: cancel).labelStyle(.iconOnly)
                .help("Return to workflow choices")
            VStack(alignment: .leading, spacing: 4) {
                TextField("Untitled workflow", text: $model.definition.name)
                    .font(.title3.weight(.semibold)).focused($nameFocused)
                    .accessibilityLabel("Workflow name").accessibilityIdentifier("designerName")
                TextField("Add a description", text: $model.definition.description)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Description").accessibilityIdentifier("designerDescription")
            }.textFieldStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
            Button("Save", action: save).buttonStyle(.borderedProminent).disabled(!model.canSave)
                .accessibilityIdentifier("designerSave")
        }.controlSize(.regular).padding(.horizontal, 20).padding(.vertical, 12)
            .background(.bar)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            status
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button("Zoom out", systemImage: "minus") { zoom = max(0.25, zoom - 0.1) }.labelStyle(.iconOnly)
                    .disabled(zoom <= 0.25).help("Zoom out")
                Button {
                    zoom = 1
                } label: {
                    Text(zoom, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 40)
                }.help("Actual size")
                Button("Zoom in", systemImage: "plus") { zoom = min(2, zoom + 0.1) }.labelStyle(.iconOnly)
                    .disabled(zoom >= 2).help("Zoom in")
                Divider().frame(height: 14)
                Button("Fit", action: fitGraph).help("Fit the graph to this canvas")
            }.buttonStyle(.borderless).controlSize(.small)
        }.font(.caption).padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
    }

    @ViewBuilder
    private var status: some View {
        if let failure = model.failure {
            Text(failure).foregroundStyle(Color.statusNeedsAttention).lineLimit(2)
            Button("Retry") { Task { await model.validate(using: client) } }
        } else if connecting != nil {
            Text("Choose the other end of this link. Press Escape to cancel.")
                .foregroundStyle(.secondary).lineLimit(2)
                .accessibilityLabel("Connect agents")
        } else if model.definition.roles.isEmpty {
            Text("Double-click to add an agent. Right-click for canvas tools.").foregroundStyle(.secondary).lineLimit(2)
        } else if model.definition.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Save without a name to use Untitled.").foregroundStyle(.secondary).lineLimit(2)
        } else if let issue = model.issues.first, !model.isValidating {
            Text(issue.message).foregroundStyle(Color.statusNeedsAttention).lineLimit(2)
                .accessibilityIdentifier("designerValidation")
        } else {
            Text("Drag agents. Click an agent or link to edit. Feedback returns changes.").foregroundStyle(.secondary)
                .lineLimit(
                    2)
        }
    }

    private func fitGraph() {
        guard viewport.width > 0, viewport.height > 0 else { return }
        zoom = WorkflowEditorLayout.fitScale(for: model.definition, viewport: viewport)
    }

    private func save() {
        Task { if let type = await model.save(using: client) { saved(type) } }
    }
}
