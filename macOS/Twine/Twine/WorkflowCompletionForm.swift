import SwiftUI

struct WorkflowCompletionForm: View {
    @Environment(CoreClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let workflowID: UInt64
    let generation: UInt64
    let agent: CoreWorkflowRun.Agent
    /// The run started without a task, so finishing the first stage records it.
    var needsTask = false
    @State private var task = ""
    @State private var decision = CoreCompletionSignal.Decision.approve
    @State private var summary = ""
    @State private var tasks: [String: String] = [:]
    @State private var files: [String: String] = [:]
    @State private var isSubmitting = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mark done").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if agent.reviewer {
                        Picker("Review decision", selection: $decision) {
                            Text("Approve").tag(CoreCompletionSignal.Decision.approve)
                            Text("Request changes").tag(CoreCompletionSignal.Decision.requestChanges)
                        }.pickerStyle(.segmented)
                    }
                    if needsTask {
                        TextField("Task you gave the agent", text: $task, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(2...6)
                            .accessibilityIdentifier("completionTask")
                    }
                    TextField(agent.reviewer ? "Review feedback" : "Result summary", text: $summary, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(3...6)
                        .accessibilityIdentifier("completionSummary")
                    ForEach(agent.targets) { target in
                        Text(target.label).font(.caption.weight(.semibold))
                        TextField("Sub-task", text: binding($tasks, key: target.id), axis: .vertical)
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("assignmentTask-\(target.id)")
                        TextField("Owned files (one per line)", text: binding($files, key: target.id), axis: .vertical)
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("assignmentFiles-\(target.id)")
                    }
                    if !agent.targets.isEmpty {
                        Text("Give each worker a separate set of files. File ownership is advisory.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let failure { Text(failure).font(.caption).foregroundStyle(Color.statusNeedsAttention) }
                }
            }.frame(maxHeight: 360)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Submit", action: submit).buttonStyle(.borderedProminent)
                    .disabled(isSubmitting).accessibilityIdentifier("completionSubmit")
            }
        }.padding(20).frame(width: 480)
    }

    private func binding(_ values: Binding<[String: String]>, key: String) -> Binding<String> {
        Binding(get: { values.wrappedValue[key] ?? "" }, set: { values.wrappedValue[key] = $0 })
    }

    private func submit() {
        guard !isSubmitting else { return }
        let signal = CoreCompletionSignal(
            decision: agent.reviewer ? decision : .done, summary: summary,
            assignments: agent.targets.map { target in
                .init(
                    role: target.role, instance: target.instance, task: tasks[target.id] ?? "",
                    files: (files[target.id] ?? "").split(separator: "\n").map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.filter { !$0.isEmpty })
            }, task: needsTask ? task : "")
        isSubmitting = true
        failure = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await client.completeWorkflowRole(
                    workflowID: workflowID, agentID: agent.id, generation: generation, signal: signal)
                dismiss()
            } catch { failure = error.localizedDescription }
        }
    }
}

#Preview {
    WorkflowCompletionForm(
        workflowID: 1, generation: 1,
        agent: .init(
            agentId: 1, active: true, done: false, reviewer: false, harness: .codex,
            targets: [
                .init(role: "worker", instance: 1, label: "Worker 1"),
                .init(role: "worker", instance: 2, label: "Worker 2"),
            ])
    )
    .environment(CoreClient(transport: CoreWorker(dataDirectory: AppPaths.previewDirectory)))
}
