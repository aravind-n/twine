import SwiftUI

struct WorkflowResultsPopover: View {
    @Environment(CoreClient.self) private var client
    let workflowID: UInt64
    let run: CoreWorkflowRun
    let reportFailure: (String) -> Void

    private var canChoose: Bool {
        run.status == .running && run.workflowType?.definition.graph?.finish == .choose
            && run.agents.allSatisfy { !$0.active } && !run.outputs.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Results").font(.headline)
                ForEach(run.outputs) { output in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(output.label).font(.headline)
                            Spacer()
                            HStack(spacing: 2) {
                                Text(Double(output.elapsedMs) / 1000, format: .number.precision(.fractionLength(2)))
                                Text("s")
                            }
                        }
                        Text(output.summary).textSelection(.enabled).font(.body)
                        if canChoose {
                            Button("Choose this result") {
                                Task {
                                    do {
                                        try await client.chooseWorkflowResult(
                                            workflowID: workflowID, generation: run.generation, agentID: output.id)
                                    } catch { reportFailure(error.localizedDescription) }
                                }
                            }
                        } else if run.selectedResult == output.id {
                            Label("Selected", systemImage: "checkmark").foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }
            }.padding(16)
        }.frame(width: 480, height: 400)
    }
}
