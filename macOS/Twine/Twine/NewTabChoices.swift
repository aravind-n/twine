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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NewTabLayout.spacing) {
                Text(showsComingSoon ? "Coming soon" : "Choose a workflow")
                    .font(.headline)
                Text(
                    showsComingSoon
                        ? "\(name) workflows are coming soon. Type below to use Terminal."
                        : "Pick a workflow type, or start typing to use Terminal."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: NewTabLayout.minimumChoiceWidth))],
                    spacing: NewTabLayout.spacing
                ) {
                    ForEach(WorkflowChoice.allCases) { choice in
                        Button {
                            choose(choice)
                        } label: {
                            HStack(spacing: NewTabLayout.spacing) {
                                Image(systemName: choice.symbol).frame(width: NewTabLayout.symbolWidth)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(choice.rawValue).font(.caption.weight(.semibold))
                                    Text(choice.detail).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(NewTabLayout.choicePadding)
                            .frame(
                                maxWidth: .infinity, minHeight: NewTabLayout.minimumChoiceHeight, alignment: .leading
                            )
                            .background(.secondarySurface, in: .rect(cornerRadius: CornerRadius.choiceTile))
                            .overlay {
                                RoundedRectangle(cornerRadius: CornerRadius.choiceTile)
                                    .stroke(.hairline, lineWidth: Surface.hairlineWidth)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("workflowChoice-\(choice.rawValue)")
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { contentHeight = $0 })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, max(0, availableHeight - 2 * NewTabLayout.padding)))
        .padding(NewTabLayout.padding)
        .background(.secondarySurface, in: .rect(cornerRadius: CornerRadius.choicesCard))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.choicesCard)
                .stroke(.hairline, lineWidth: Surface.hairlineWidth)
        }
        .accessibilityIdentifier("newTabChoices")
    }
}
