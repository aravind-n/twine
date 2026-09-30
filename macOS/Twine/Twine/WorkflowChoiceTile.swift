import SwiftUI

struct ChoiceTile: View {
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
                MenuChevron()
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
