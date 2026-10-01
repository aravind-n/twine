import SwiftUI

struct WorkflowHandoffEditor: View {
    @Binding var handoff: CoreWorkflowType.Handoff
    let definition: CoreWorkflowType.Definition
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WorkflowEndpointEditor(title: "From", endpoint: $handoff.from, definition: definition)
            WorkflowEndpointEditor(title: "To", endpoint: $handoff.destination, definition: definition)
            HStack {
                Picker("Pass", selection: $handoff.content) {
                    Text("Result").tag(CoreWorkflowType.HandoffContent.result)
                    Text("Assignment and owned files").tag(CoreWorkflowType.HandoffContent.assignment)
                    Text("Review feedback").tag(CoreWorkflowType.HandoffContent.feedback)
                }
                Button("Remove handoff", systemImage: "minus.circle", action: remove)
            }
        }
    }
}

private struct WorkflowEndpointEditor: View {
    let title: String
    @Binding var endpoint: CoreWorkflowType.Endpoint
    let definition: CoreWorkflowType.Definition

    private var roles: [CoreWorkflowType.Role] {
        let stage = definition.stages.first { $0.id == endpoint.stage }
        return definition.roles.filter { stage?.roles.contains($0.id) == true }
    }

    var body: some View {
        HStack {
            Picker(
                "\(title) stage",
                selection: Binding(
                    get: { endpoint.stage },
                    set: { stage in
                        endpoint.stage = stage
                        endpoint.role = definition.stages.first { $0.id == stage }?.roles.first ?? ""
                    })
            ) {
                Text("Choose a stage").tag("")
                ForEach(definition.stages) { Text($0.name).tag($0.id) }
            }
            Picker("\(title) role", selection: $endpoint.role) {
                Text("Choose a role").tag("")
                if !endpoint.role.isEmpty && !roles.contains(where: { $0.id == endpoint.role }) {
                    Text("Role no longer in stage").tag(endpoint.role)
                }
                ForEach(roles) { role in
                    Label(role.name, systemImage: RoleStyle(role: role.name).symbol)
                        .foregroundStyle(RoleStyle(role: role.name).color).tag(role.id)
                }
            }
        }
    }
}

struct WorkflowLoopEditor: View {
    @Binding var loop: CoreWorkflowType.ReviewLoop
    let stages: [CoreWorkflowType.Stage]
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Review stage", selection: $loop.reviewStage) {
                Text("Choose a stage").tag("")
                ForEach(stages) { Text($0.name).tag($0.id) }
            }
            Picker("Return to", selection: $loop.backTo) {
                Text("Choose an earlier stage").tag("")
                ForEach(stages) { Text($0.name).tag($0.id) }
            }
            HStack {
                Stepper("Maximum rounds: \(loop.maxRounds)", value: $loop.maxRounds, in: 1...10)
                Spacer()
                Button("Remove loop", systemImage: "minus.circle", action: remove)
            }
        }
    }
}

#Preview {
    @Previewable @State var loop = CoreWorkflowType.ReviewLoop(reviewStage: "", backTo: "", maxRounds: 3)
    WorkflowLoopEditor(loop: $loop, stages: []) { loop.maxRounds = 1 }.padding()
}
