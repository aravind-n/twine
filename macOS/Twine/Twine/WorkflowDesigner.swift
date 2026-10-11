import SwiftUI

struct WorkflowDesigner: View {
    @Environment(CoreClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appZoomMaximumPresentationSize) private var maximum
    @State private var model: WorkflowDesignerModel
    @State private var section = Section.roles
    @FocusState private var nameFocused: Bool
    let saved: (CoreWorkflowType) -> Void

    enum Section: String, CaseIterable {
        case roles = "Roles"
        case stages = "Stages"
        case handoffs = "Handoffs"
        case loops = "Review loops"
        case preview = "Preview"
    }

    init(type: CoreWorkflowType? = nil, saved: @escaping (CoreWorkflowType) -> Void) {
        _model = State(initialValue: WorkflowDesignerModel(type: type))
        self.saved = saved
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text(model.source == nil ? "Create a workflow type" : "Edit workflow type")
                .font(.system(size: 16, weight: .semibold))
            if model.source?.builtin != nil {
                Text("Saving creates your own copy of this built-in type.").foregroundStyle(.secondary)
            }
            TextField("Name", text: $model.definition.name).focused($nameFocused)
                .accessibilityIdentifier("designerName")
            errors("name")
            TextField("Description", text: $model.definition.description, axis: .vertical).lineLimit(1...3)
                .accessibilityIdentifier("designerDescription")
            Picker("Designer section", selection: $section) {
                ForEach(Section.allCases, id: \.self) { section in
                    Text(sectionTitle(section)).tag(section)
                }
            }.pickerStyle(.segmented).accessibilityIdentifier("designerSections")
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch section {
                    case .roles: roleEditors
                    case .stages: stageEditors
                    case .handoffs: handoffEditors
                    case .loops: loopEditors
                    case .preview:
                        WorkflowGraph(type: .init(reference: .init(builtin: "designer"), definition: model.definition))
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 17))
            .overlay { RoundedRectangle(cornerRadius: 17).stroke(.hairline, lineWidth: 1) }
            .accessibilityIdentifier("designerContent")
            if let failure = model.failure {
                HStack {
                    Text(failure).foregroundStyle(Color.statusNeedsAttention)
                    Button("Retry validation") { Task { await model.validate(using: client) } }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Text(validationSummary).foregroundStyle(.secondary).accessibilityIdentifier("designerValidation")
                    .accessibilityLabel(validationSummary)
            }
        }
        .font(.caption).controlSize(.small).textFieldStyle(.roundedBorder)
        .padding(16)
        .frame(
            minWidth: min(580, maximum.width), idealWidth: min(760, maximum.width), maxWidth: maximum.width,
            minHeight: min(430, maximum.height), idealHeight: min(600, maximum.height), maxHeight: maximum.height
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(model.isSaving)
        .interactiveDismissDisabled(model.isSaving)
        .task(id: model.definition) { await model.validate(using: client) }
        .onAppear { nameFocused = true }
        .focusedSceneValue(\.saveAction, SaveAction(isEnabled: model.canSave, perform: save))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflowDesigner")
    }

    private var validationSummary: String {
        if model.isSaving { return "Saving…" }
        if model.failure != nil { return "Validation unavailable" }
        if model.isValidating { return "Checking design…" }
        if model.issues.isEmpty { return "Ready to save with ⌘S" }
        return model.issues.count == 1 ? "1 issue to fix" : "\(model.issues.count) issues to fix"
    }

    private func save() {
        Task {
            if let type = await model.save(using: client) {
                saved(type)
                dismiss()
            }
        }
    }

    private func sectionTitle(_ section: Section) -> String {
        let prefix: String
        switch section {
        case .roles: prefix = "roles"
        case .stages: prefix = "stages"
        case .handoffs: prefix = "handoffs"
        case .loops: prefix = "review_loops"
        case .preview: return section.rawValue
        }
        let count = model.issues.filter { $0.element.hasPrefix(prefix) }.count
        return count == 0 ? section.rawValue : "\(section.rawValue) (\(count))"
    }

    func errors(_ path: String) -> some View {
        let issues = model.isValidating ? [] : model.issues.filter { $0.element == path }
        return ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
            Label(issue.message, systemImage: "exclamationmark.circle")
                .foregroundStyle(Color.statusNeedsAttention)
                .accessibilityIdentifier("designerError-\(path)")
        }
    }

    var roleEditors: some View {
        VStack(alignment: .leading, spacing: 12) {
            errors("roles")
            ForEach(Array(model.definition.roles.enumerated()), id: \.element.id) { index, role in
                WorkflowRoleEditor(role: model.roleBinding(role)) { model.removeRole(at: index) }
                errors("roles[\(index)]")
                Divider()
            }
            Button("Add role", systemImage: "plus", action: model.addRole).accessibilityIdentifier("designerAddRole")
        }
    }

    var stageEditors: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stages run from top to bottom. Roles in a stage run in parallel.").foregroundStyle(.secondary)
            errors("stages")
            ForEach(Array(model.definition.stages.enumerated()), id: \.element.id) { index, stage in
                WorkflowStageEditor(
                    stage: model.stageBinding(stage), roles: model.definition.roles,
                    index: index, count: model.definition.stages.count,
                    move: { offset in model.definition.stages.swapAt(index, index + offset) },
                    remove: { model.removeStage(at: index) })
                errors("stages[\(index)]")
                Divider()
            }
            Button("Add stage", systemImage: "plus", action: model.addStage).accessibilityIdentifier("designerAddStage")
        }
    }

    var handoffEditors: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect each role to the next stage, or send reviewer feedback along a review loop.")
                .foregroundStyle(.secondary)
            ForEach(Array(zip(model.handoffIDs, model.definition.handoffs)), id: \.0) { id, handoff in
                let index = model.handoffIDs.firstIndex(of: id) ?? 0
                WorkflowHandoffEditor(
                    handoff: model.handoffBinding(handoff, id: id), definition: model.definition,
                    remove: { model.removeHandoff(at: index) })
                errors("handoffs[\(index)]")
                Divider()
            }
            Button("Add handoff", systemImage: "plus", action: model.addHandoff)
                .accessibilityIdentifier("designerAddHandoff")
        }
    }

    var loopEditors: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A review decision sends feedback to an earlier stage, up to the round limit.")
                .foregroundStyle(.secondary)
            ForEach(Array(zip(model.loopIDs, model.definition.reviewLoops)), id: \.0) { id, loop in
                let index = model.loopIDs.firstIndex(of: id) ?? 0
                WorkflowLoopEditor(
                    loop: model.loopBinding(loop, id: id), stages: model.definition.stages,
                    remove: { model.removeLoop(at: index) })
                errors("review_loops[\(index)]")
                Divider()
            }
            Button("Add review loop", systemImage: "plus", action: model.addLoop)
                .accessibilityIdentifier("designerAddLoop")
        }
    }
}

#Preview {
    WorkflowDesigner { _ in }.environment(CoreClient(transport: CoreWorker(dataDirectory: AppPaths.previewDirectory)))
}
