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

    var detail: String {
        switch self {
        case .terminal: "An interactive shell"
        case .singleAgent: "One agent — coming soon"
        case .adversarial: "Agents review each other — coming soon"
        case .coordinator: "A coordinator directs agents — coming soon"
        }
    }
}

struct NewTabChoices: View {
    let name: String
    let availableHeight: CGFloat
    let choose: (WorkflowChoice) -> Void
    @State private var contentHeight: CGFloat = 0

    private var showsComingSoon: Bool {
        WorkflowChoice.allCases.contains { $0 != .terminal && $0.rawValue == name }
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
            VStack(alignment: .leading, spacing: NewTabLayout.sectionSpacing) {
                VStack(alignment: .leading, spacing: NewTabLayout.headingSpacing) {
                    Text(showsComingSoon ? "Coming soon" : "Choose a workflow")
                        .font(.system(size: 14, weight: .bold))
                    Text(
                        showsComingSoon
                            ? "\(name) workflows are coming soon. Start typing to use Terminal."
                            : "Pick a workflow type, or start typing to use Terminal."
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: NewTabLayout.minimumChoiceWidth))],
                    spacing: NewTabLayout.spacing
                ) {
                    ForEach(WorkflowChoice.allCases) { choice in
                        Button {
                            choose(choice)
                        } label: {
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
                            }
                            .padding(NewTabLayout.choicePadding)
                            .frame(
                                maxWidth: .infinity, minHeight: NewTabLayout.minimumChoiceHeight, alignment: .topLeading
                            )
                            .background(.workflowChoiceBackground, in: .rect(cornerRadius: CornerRadius.choiceTile))
                            .overlay {
                                RoundedRectangle(cornerRadius: CornerRadius.choiceTile)
                                    .stroke(.hairline, lineWidth: Surface.hairlineWidth)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(choice.detail)
                        .accessibilityIdentifier("workflowChoice-\(choice.rawValue)")
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { contentHeight = $0 })
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
}
