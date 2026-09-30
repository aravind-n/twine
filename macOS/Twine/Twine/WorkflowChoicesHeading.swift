import SwiftUI

/// The card's title and the line of guidance under it.
struct ChoicesHeading: View {
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
