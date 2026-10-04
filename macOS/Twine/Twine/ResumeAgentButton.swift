import SwiftUI

/// Older tabs and harnesses without session hooks can still resume a conversation by its ID.
struct ResumeAgentButton: View {
    @Environment(CoreClient.self) private var client
    let workflow: CoreWorkflow
    @State private var isPresented = false
    @State private var session = ""
    @State private var isResuming = false
    @State private var failure: String?

    private var usesFile: Bool { workflow.harness == .piAgent || workflow.harness == .omp }

    var body: some View {
        Button("Resume Session…") { isPresented = true }
            .accessibilityIdentifier("resumeAgentSession")
            .sheet(isPresented: $isPresented) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Resume \(workflow.name)").font(.headline)
                    Text(
                        usesFile
                            ? "Enter the absolute path to this agent's saved session file."
                            : "Enter the session ID from the harness's conversation history."
                    )
                    .foregroundStyle(.secondary)
                    TextField(usesFile ? "Session file path" : "Session ID", text: $session)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("resumeSessionID")
                    if let failure { Text(failure).foregroundStyle(.red).font(.caption) }
                    HStack {
                        Spacer()
                        Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                            .disabled(isResuming)
                        Button(isResuming ? "Resuming…" : "Resume") { isResuming = true }
                            .keyboardShortcut(.defaultAction)
                            .disabled(isResuming || session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(24).frame(width: 420)
                .interactiveDismissDisabled(isResuming)
                .task(id: isResuming) {
                    guard isResuming else { return }
                    do {
                        try await client.resumeAgent(workflowID: workflow.id, session: session)
                        isPresented = false
                    } catch { failure = error.localizedDescription }
                    isResuming = false
                }
                .appZoom()
            }
    }
}

#Preview {
    ResumeAgentButton(
        workflow: .init(
            workflowID: 1, sessionID: 1, name: "Codex", kind: .singleAgent, harness: .codex,
            terminalID: 1, status: .interrupted, startedAt: 0, endedAt: 1, restored: true)
    )
    .environment(CoreClient(transport: CoreWorker(dataDirectory: .temporaryDirectory)))
    .padding()
}
