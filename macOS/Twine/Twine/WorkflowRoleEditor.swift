import SwiftUI

struct WorkflowRoleEditor: View {
    @Binding var role: CoreWorkflowType.Role
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(role.name, systemImage: RoleStyle(role: role.name).symbol)
                    .foregroundStyle(RoleStyle(role: role.name).color).fontWeight(.semibold)
                Spacer()
                Button("Remove role", systemImage: "minus.circle", action: remove)
            }
            TextField("Role name", text: $role.name).accessibilityIdentifier("designerRoleName-\(role.id)")
            TextField("Instructions", text: $role.instructions, axis: .vertical).lineLimit(2...6)
                .accessibilityIdentifier("designerRoleInstructions-\(role.id)")
            HStack {
                Stepper("Minimum agents: \(role.instances.min)", value: $role.instances.min, in: 1...5)
                Stepper("Maximum agents: \(role.instances.max)", value: $role.instances.max, in: 1...5)
            }
        }
    }
}

struct WorkflowStageEditor: View {
    @Binding var stage: CoreWorkflowType.Stage
    let roles: [CoreWorkflowType.Role]
    let index: Int
    let count: Int
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("STAGE \(index + 1)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Move up", systemImage: "arrow.up") { move(-1) }.disabled(index == 0)
                Button("Move down", systemImage: "arrow.down") { move(1) }.disabled(index + 1 == count)
                Button("Remove stage", systemImage: "minus.circle", action: remove)
            }
            TextField("Stage name", text: $stage.name).accessibilityIdentifier("designerStageName-\(stage.id)")
            ForEach(roles) { role in
                Toggle(
                    isOn: Binding(
                        get: { stage.roles.contains(role.id) },
                        set: { selected in
                            stage.roles.removeAll { $0 == role.id }
                            if selected { stage.roles.append(role.id) }
                        })
                ) {
                    Label(role.name, systemImage: RoleStyle(role: role.name).symbol)
                        .foregroundStyle(RoleStyle(role: role.name).color)
                }.toggleStyle(.checkbox)
            }
            Picker(
                "Completion",
                selection: Binding(
                    get: { stage.completion.rule },
                    set: { rule in
                        stage.completion = .init(
                            rule: rule, reviewer: rule == .reviewDecision ? stage.roles.first ?? "" : nil)
                    })
            ) {
                Text("All roles done").tag(CoreWorkflowType.CompletionRule.allRolesDone)
                Text("Review decision").tag(CoreWorkflowType.CompletionRule.reviewDecision)
            }
            if stage.completion.rule == .reviewDecision {
                Picker(
                    "Reviewer",
                    selection: Binding(
                        get: { stage.completion.reviewer ?? "" }, set: { stage.completion.reviewer = $0 })
                ) {
                    Text("Choose a reviewer").tag("")
                    ForEach(roles.filter { stage.roles.contains($0.id) }) { role in Text(role.name).tag(role.id) }
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var role = CoreWorkflowType.Role(id: "author", name: "Author", instances: .init(min: 1, max: 1))
    WorkflowRoleEditor(role: $role) { role.name = "" }.padding()
}
