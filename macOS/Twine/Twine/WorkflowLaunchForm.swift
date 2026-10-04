import SwiftUI

struct WorkflowLaunchForm: View {
    @Environment(CoreClient.self) private var client
    let workflowID: UInt64
    let type: CoreWorkflowType
    var isSelected = true
    let back: () -> Void
    @Environment(HarnessModelCatalog.self) private var catalog
    /// Each role's harness choices, one per instance.
    @State private var showsDesigner = false
    @State private var choices: [String: [HarnessChoice]] = [:]
    @State private var isStarting = false
    @State private var failure: String?
    @State private var hasLoaded = false
    private let preferences = WorkflowLaunchPreferences()

    var body: some View {
        VStack(alignment: .leading, spacing: NewTabLayout.sectionSpacing) {
            Text(type.definition.name).font(.system(size: 14, weight: .bold))
            Button(type.reference.builtin == nil ? "Edit workflow type" : "Edit a copy", systemImage: "pencil") {
                showsDesigner = true
            }
            .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(isStarting || !isSelected)
            .help("Edit workflow type (⇧⌘E)")
            .accessibilityIdentifier("workflowEditType")
            Text(type.definition.description).font(.caption).foregroundStyle(.secondary)
            WorkflowGraph(type: type, counts: choices.mapValues(\.count))
            ForEach(type.definition.roles) { role in
                rolePickers(role)
            }
            if let first = firstRoleName {
                Text("After you start, tell the \(first) what to do in its terminal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(Color.statusNeedsAttention)
                    .accessibilityIdentifier("workflowStartFailure")
            }
            HStack {
                Button("Back", action: back)
                    .keyboardShortcut(isSelected && !showsDesigner ? .cancelAction : nil)
                    .disabled(isStarting)
                Spacer()
                Button("Start", action: start)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(isSelected && !showsDesigner ? .defaultAction : nil)
                    .disabled(isStarting)
                    .accessibilityIdentifier("workflowStart")
            }.controlSize(.small)
        }
        .sheet(isPresented: $showsDesigner) {
            WorkflowDesigner(type: type) { _ in back() }.environment(client).appZoom()
        }
        .onAppear {
            if !hasLoaded {
                choices = preferences.choices(for: type)
                hasLoaded = true
            }
        }
        .task(id: client.snapshot?.folders.openFolder) { await catalog.load(using: client) }
    }

    /// The role that starts the run, which the user talks to first.
    private var firstRoleName: String? {
        type.definition.stages.first?.roles.first.flatMap { id in type.definition.roles.first { $0.id == id }?.name }
    }

    private func rolePickers(_ role: CoreWorkflowType.Role) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if role.instances.max > role.instances.min {
                Stepper(
                    "\(role.name): \(choices[role.id]?.count ?? role.instances.min)",
                    value: Binding(
                        get: { choices[role.id]?.count ?? role.instances.min },
                        set: { count in
                            let old = choices[role.id] ?? []
                            // A new instance starts like the last one.
                            let fill = old.last ?? HarnessChoice(harness: .codex)
                            choices[role.id] =
                                Array(old.prefix(count)) + Array(repeating: fill, count: max(0, count - old.count))
                        }), in: role.instances.min...role.instances.max)
            }
            ForEach(0..<(choices[role.id]?.count ?? 0), id: \.self) { index in
                HarnessChoiceRow(
                    title: role.instances.max > 1 ? "\(role.name) \(index + 1)" : role.name,
                    symbol: RoleStyle(role: role.name).symbol, color: RoleStyle(role: role.name).color,
                    choice: Binding(
                        get: { choices[role.id]?[index] ?? HarnessChoice(harness: .codex) },
                        set: { choices[role.id]?[index] = $0 }),
                    identifier: "\(role.id)-\(index)")
            }
        }.font(.caption).disabled(isStarting)
    }

    private func start() {
        guard !isStarting else { return }
        let roles = type.definition.roles.flatMap { role in
            (choices[role.id] ?? []).map { CoreRoleLaunch(role: role.id, choice: $0) }
        }
        let assignments = choices
        isStarting = true
        failure = nil
        Task {
            defer { isStarting = false }
            do {
                try await client.startWorkflowRun(workflowID: workflowID, workflowType: type.reference, roles: roles)
                preferences.remember(assignments, for: type)
            } catch { failure = error.localizedDescription }
        }
    }
}

#Preview {
    @Previewable @State var visible = true
    if visible {
        WorkflowLaunchForm(
            workflowID: 1,
            type: .init(
                reference: .init(builtin: "adversarial"),
                definition: .init(
                    name: "Adversarial", description: "Implement, then review.",
                    roles: [
                        .init(id: "implementer", name: "Implementer", instances: .init(min: 1, max: 1)),
                        .init(id: "reviewer", name: "Reviewer", instances: .init(min: 1, max: 1)),
                    ]))
        ) { visible = false }
        .environment(CoreClient(transport: CoreWorker(dataDirectory: .temporaryDirectory)))
        .environment(HarnessModelCatalog())
        .padding().frame(width: 550)
    } else {
        Button("Show launch form") { visible = true }
    }
}
