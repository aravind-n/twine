import SwiftUI

enum WorkflowChoice: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case singleAgent = "Single agent"
    case adversarial = "Adversarial"
    case coordinator = "Coordinator"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .terminal: "terminal"
        case .singleAgent: "person"
        case .adversarial: "person.2"
        case .coordinator: "person.3"
        }
    }

    /// Choices that open a menu instead of acting immediately show a chevron.
    var opensMenu: Bool { self == .singleAgent }

    var detail: String {
        switch self {
        case .terminal: "An interactive shell"
        case .singleAgent: "One agent runs your prompt"
        case .adversarial: "Agents review each other — coming soon"
        case .coordinator: "A coordinator directs agents — coming soon"
        }
    }
}

struct NewTabChoices: View {
    let name: String
    let availableHeight: CGFloat
    let isSelected: Bool
    let choose: (WorkflowChoice) -> Void
    /// Runs `prompt` with the harness in the draft's folder. Throws the reason it couldn't start.
    let startAgent: (BridgeHarness, String) async throws -> Void
    /// Gives the keyboard back to the terminal, which nothing else in the card can take.
    let focusTerminal: () -> Void
    @State private var contentHeight: CGFloat = 0
    @State private var harness: BridgeHarness?

    private var showsComingSoon: Bool {
        [WorkflowChoice.adversarial, .coordinator].contains { $0.rawValue == name }
    }

    private var verticalPadding: CGFloat {
        min(
            NewTabLayout.padding,
            max(0, (availableHeight - NewTabLayout.promptClearance - NewTabLayout.minimumChoiceHeight) / 2))
    }

    private var viewportHeight: CGFloat {
        min(contentHeight, max(0, availableHeight - NewTabLayout.promptClearance - 2 * verticalPadding))
    }

    private var verticalOffset: CGFloat {
        max(0, NewTabLayout.promptClearance - (availableHeight - viewportHeight - 2 * verticalPadding) / 2)
    }

    var body: some View {
        ScrollView {
            if let harness {
                AgentPromptForm(
                    harness: Binding(get: { harness }, set: { self.harness = $0 }),
                    isSelected: isSelected,
                    back: {
                        self.harness = nil
                        focusTerminal()
                    },
                    start: startAgent
                )
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { contentHeight = $0 })
            } else {
                choices
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { contentHeight = $0 })
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: viewportHeight)
        .padding(.horizontal, NewTabLayout.padding)
        .padding(.vertical, verticalPadding)
        .background(.workflowChoicesBackground, in: .rect(cornerRadius: CornerRadius.choicesCard))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.choicesCard)
                .stroke(.hairline, lineWidth: Surface.hairlineWidth)
        }
        .accessibilityIdentifier("newTabChoices")
        .offset(y: verticalOffset)
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: NewTabLayout.sectionSpacing) {
            ChoicesHeading(
                title: showsComingSoon ? "Coming soon" : "Choose a workflow",
                message: showsComingSoon
                    ? "\(name) workflows are coming soon. Start typing to use Terminal."
                    : "Pick a workflow type, or start typing to use Terminal.")

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: NewTabLayout.minimumChoiceWidth))],
                spacing: NewTabLayout.spacing
            ) {
                ForEach(WorkflowChoice.allCases) { choice in
                    if choice.opensMenu {
                        Menu {
                            ForEach(BridgeHarness.allCases) { harness in
                                Button(harness.displayName) { self.harness = harness }
                                    .accessibilityIdentifier("harness-\(harness.rawValue)")
                            }
                        } label: {
                            ChoiceTile(choice: choice)
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        .help(choice.detail)
                        .accessibilityIdentifier("workflowChoice-\(choice.rawValue)")
                    } else {
                        Button {
                            choose(choice)
                        } label: {
                            ChoiceTile(choice: choice)
                        }
                        .buttonStyle(.plain)
                        .help(choice.detail)
                        .accessibilityIdentifier("workflowChoice-\(choice.rawValue)")
                    }
                }
            }
        }
    }
}

private struct ChoiceTile: View {
    let choice: WorkflowChoice

    var body: some View {
        HStack(alignment: .top, spacing: NewTabLayout.spacing) {
            Image(systemName: choice.symbol)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: NewTabLayout.symbolWidth, height: NewTabLayout.symbolWidth)
            VStack(alignment: .leading, spacing: NewTabLayout.choiceTextSpacing) {
                Text(choice.rawValue).font(.caption.weight(.semibold))
                Text(choice.detail)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if choice.opensMenu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(NewTabLayout.choicePadding)
        .frame(maxWidth: .infinity, minHeight: NewTabLayout.minimumChoiceHeight, alignment: .topLeading)
        .background(.workflowChoiceBackground, in: .rect(cornerRadius: CornerRadius.choiceTile))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.choiceTile)
                .stroke(.hairline, lineWidth: Surface.hairlineWidth)
        }
        .contentShape(.rect)
    }
}

/// The prompt for a single agent, shown in the choices card once a harness is picked.
private struct AgentPromptForm: View {
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

/// The card's title and the line of guidance under it.
private struct ChoicesHeading: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: NewTabLayout.headingSpacing) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
            Text(message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}
