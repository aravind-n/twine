import SwiftUI

struct NewTabChoices: View {
    @Environment(CoreClient.self) private var client
    let workflowID: UInt64
    let availableHeight: CGFloat
    let isSelected: Bool
    let choose: (WorkflowChoice) -> Void
    /// Runs `prompt` with the harness in the draft's folder. Throws the reason it couldn't start.
    let startAgent: (CoreHarness, String) async throws -> Void
    /// Gives the keyboard back to the terminal, which nothing else in the card can take.
    let focusTerminal: () -> Void
    @State private var contentHeight: CGFloat = 0
    @Binding var harness: CoreHarness?
    @Binding var selectedType: CoreWorkflowType?
    private var catalog: [CoreWorkflowType] { client.snapshot?.workflowTypes ?? [] }

    // A prompt form owns keyboard input, so it can use the space reserved for the shell prompt.
    private var showsPrompt: Bool { harness != nil || selectedType != nil }
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
            } else if let harness {
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

            // These two lightweight launch paths stay mounted even when a short card must scroll.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: NewTabLayout.spacing) { quickChoices }
                    .frame(minWidth: 2 * NewTabLayout.minimumChoiceWidth + NewTabLayout.spacing)
                VStack(spacing: NewTabLayout.spacing) { quickChoices }
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: NewTabLayout.minimumChoiceWidth))],
                spacing: NewTabLayout.spacing
            ) {
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
