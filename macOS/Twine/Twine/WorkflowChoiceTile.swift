import SwiftUI

struct ChoiceTile: View {
    let symbol: String
    let title: String
    let detail: String
    var opensMenu = false

    init(choice: WorkflowChoice) {
        self.init(
            symbol: choice.symbol, title: choice.rawValue, detail: choice.detail, opensMenu: choice.opensMenu)
    }

    init(symbol: String, title: String, detail: String, opensMenu: Bool = false) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.opensMenu = opensMenu
    }

    var body: some View {
        HStack(alignment: .top, spacing: NewTabLayout.spacing) {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: NewTabLayout.symbolWidth, height: NewTabLayout.symbolWidth)
            VStack(alignment: .leading, spacing: NewTabLayout.choiceTextSpacing) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if opensMenu {
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
