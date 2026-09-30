import SwiftUI

/// The prompt for a single agent, shown in the choices card once a harness is picked.
struct AgentPromptForm: View {
    @Binding var harness: BridgeHarness
    let isSelected: Bool
    let back: () -> Void
    let start: (BridgeHarness, String) async throws -> Void
    @State private var prompt = ""
    @State private var isStarting = false
    @State private var failureMessage: String?
    @FocusState private var isPromptFocused: Bool

    private var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: NewTabLayout.sectionSpacing) {
            ChoicesHeading(
                title: "Single agent",
                message: "Give the agent a prompt. It starts in this folder and you can interact with it here.")
            HStack(alignment: .top, spacing: NewTabLayout.spacing) {
                Picker("Harness", selection: $harness) {
                    ForEach(BridgeHarness.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("agentHarness")
                TextField("Prompt", text: $prompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .focused($isPromptFocused)
                    .onSubmit(submit)
                    .accessibilityIdentifier("agentPrompt")
            }
            if let failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.statusNeedsAttention)
                    .accessibilityIdentifier("agentStartFailure")
            }
            HStack(spacing: NewTabLayout.spacing) {
                Button("Back", action: back)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button("Start", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedPrompt.isEmpty || isStarting)
                    .accessibilityIdentifier("agentStart")
            }
            .controlSize(.small)
        }
        .onAppear { isPromptFocused = true }
        // Selecting the tab again gives the terminal underneath the keyboard first.
        .onChange(of: isSelected) { _, isSelected in if isSelected { isPromptFocused = true } }
    }

    private func submit() {
        guard !trimmedPrompt.isEmpty, !isStarting else { return }
        isStarting = true
        failureMessage = nil
        Task {
            defer { isStarting = false }
            do {
                try await start(harness, trimmedPrompt)
            } catch {
                failureMessage = error.localizedDescription
            }
        }
    }
}
