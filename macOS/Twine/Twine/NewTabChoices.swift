import SwiftUI

struct NewTabChoices: View {
    @Environment(CoreClient.self) private var client
    let workflowID: UInt64
    let availableHeight: CGFloat
    let isSelected: Bool
    let choose: (WorkflowChoice) -> Void
    /// Starts the harness in the draft's folder, waiting for the user. Throws the reason it couldn't start.
    let startAgent: (CoreHarness) async throws -> Void
    /// Gives the keyboard back to the terminal, which nothing else in the card can take.
    let focusTerminal: () -> Void
    @State private var contentHeight: CGFloat = 0
    @State private var startFailure: String?
    @Binding var selectedType: CoreWorkflowType?
    /// Set while a picked harness starts, so keys typed meanwhile can't turn the draft into a shell.
    @Binding var startingHarness: CoreHarness?
    private var catalog: [CoreWorkflowType] { client.snapshot?.workflowTypes ?? [] }

    // A launch form owns keyboard input, so it can use the space reserved for the shell prompt.
    private var showsPrompt: Bool { selectedType != nil }
    private var promptClearance: CGFloat { showsPrompt ? 0 : NewTabLayout.promptClearance }

    private var verticalPadding: CGFloat {
        let minimumHeight = showsPrompt ? 2 * NewTabLayout.minimumChoiceHeight : NewTabLayout.minimumChoiceHeight
        return min(
            NewTabLayout.padding,
            max(0, (availableHeight - promptClearance - minimumHeight) / 2))
    }

    private var viewportHeight: CGFloat {
        min(contentHeight, max(0, availableHeight - promptClearance - 2 * verticalPadding))
    }

    private var verticalOffset: CGFloat {
        max(0, promptClearance - (availableHeight - viewportHeight - 2 * verticalPadding) / 2)
    }

    var body: some View {
        ScrollView {
            if let selectedType {
                WorkflowLaunchForm(workflowID: workflowID, type: selectedType, isSelected: isSelected) {
                    self.selectedType = nil
                    focusTerminal()
                }
                .id(selectedType.id)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { contentHeight = $0 })
            } else {
                choices
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { contentHeight = $0 })
            }
        }
        // Short forms keep the prompt and actions visible; their introductory text can scroll.
        .defaultScrollAnchor(showsPrompt ? .bottom : .top)
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
                title: "Choose a workflow", message: "Pick a workflow type, or start typing to use Terminal.")
            if let startFailure {
                Label(startFailure, systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.statusNeedsAttention)
                    .accessibilityIdentifier("agentStartFailure")
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: NewTabLayout.minimumChoiceWidth), spacing: NewTabLayout.spacing)],
                spacing: NewTabLayout.spacing
            ) {
                quickChoices
                ForEach(catalog) { type in
                    Button {
                        selectedType = type
                    } label: {
                        WorkflowTypeChoiceTile(type: type)
                    }
                    .buttonStyle(.plain)
                    .help(type.definition.description)
                    .accessibilityIdentifier(
                        type.reference.builtin == nil
                            ? "workflowChoice-\(type.id)" : "workflowChoice-\(type.definition.name)")
                }
            }
        }
    }

    private var quickChoices: some View {
        ForEach(WorkflowChoice.allCases) { choice in
            if choice.opensMenu {
                Menu {
                    ForEach(CoreHarness.allCases) { harness in
                        Button(harness.displayName) { start(harness) }
                            .accessibilityIdentifier("harness-\(harness.rawValue)")
                    }
                } label: {
                    ChoiceTile(choice: choice)
                }
                .disabled(startingHarness != nil)
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

    private func start(_ harness: CoreHarness) {
        guard startingHarness == nil else { return }
        startingHarness = harness
        startFailure = nil
        Task {
            defer { startingHarness = nil }
            do { try await startAgent(harness) } catch { startFailure = error.localizedDescription }
        }
    }
}
