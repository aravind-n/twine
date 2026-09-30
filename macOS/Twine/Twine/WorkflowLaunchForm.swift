import SwiftUI

struct WorkflowLaunchForm: View {
    @Environment(BridgeClient.self) private var client
    let workflowID: UInt64
    let type: BridgeWorkflowType
    var isSelected = true
    let back: () -> Void
    @State private var prompt = ""
    @State private var harnesses: [String: [BridgeHarness]] = [:]
    @State private var isStarting = false
    @State private var failure: String?
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: NewTabLayout.sectionSpacing) {
            Text(type.definition.name).font(.system(size: 14, weight: .bold))
            Text(type.definition.description).font(.caption).foregroundStyle(.secondary)
            ForEach(type.definition.roles) { role in
                rolePickers(role)
            }
            TextField("Prompt", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...6).focused($promptFocused)
                .accessibilityIdentifier("workflowPrompt")
            if let failure {
                Text(failure).font(.caption).foregroundStyle(Color.statusNeedsAttention)
                    .accessibilityIdentifier("workflowStartFailure")
            }
            HStack {
                Button("Back", action: back).disabled(isStarting)
                Spacer()
                Button("Start", action: start)
                    .buttonStyle(.borderedProminent)
                    .disabled(isStarting || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("workflowStart")
            }.controlSize(.small)
        }
        .onAppear {
            for role in type.definition.roles {
                harnesses[role.id] = Array(repeating: .codex, count: role.instances.min)
            }
            promptFocused = true
        }
        .onChange(of: isSelected) { _, selected in if selected { promptFocused = true } }
    }

    private func rolePickers(_ role: BridgeWorkflowType.Role) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if role.instances.max > role.instances.min {
                Stepper(
                    "\(role.name): \(harnesses[role.id]?.count ?? role.instances.min)",
                    value: Binding(
                        get: { harnesses[role.id]?.count ?? role.instances.min },
                        set: { count in
                            let old = harnesses[role.id] ?? []
                            harnesses[role.id] =
                                Array(old.prefix(count)) + Array(repeating: .codex, count: max(0, count - old.count))
                        }), in: role.instances.min...role.instances.max)
            }
            ForEach(0..<(harnesses[role.id]?.count ?? 0), id: \.self) { index in
                Picker(
                    role.instances.max > 1 ? "\(role.name) \(index + 1)" : role.name,
                    selection: Binding(
                        get: { harnesses[role.id]?[index] ?? .codex },
                        set: { harnesses[role.id]?[index] = $0 })
                ) {
                    ForEach(BridgeHarness.allCases) { Text($0.displayName).tag($0) }
                }.accessibilityIdentifier("roleHarness-\(role.id)-\(index)")
            }
        }.font(.caption).disabled(isStarting)
    }

    private func start() {
        guard !isStarting else { return }
        let roles = type.definition.roles.flatMap { role in
            (harnesses[role.id] ?? []).map { BridgeRoleLaunch(role: role.id, harness: $0) }
        }
        isStarting = true
        failure = nil
        Task {
            defer { isStarting = false }
            do {
                try await client.startWorkflowRun(
                    workflowID: workflowID, workflowType: type.reference, prompt: prompt, roles: roles)
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
        .environment(BridgeClient(transport: BridgeWorker(dataDirectory: .temporaryDirectory)))
        .padding().frame(width: 550)
    } else {
        Button("Show launch form") { visible = true }
    }
}
