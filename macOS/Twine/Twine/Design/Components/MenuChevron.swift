import SwiftUI

/// The small chevron on a control that opens a menu.
struct MenuChevron: View {
    var foreground: Color = .secondary

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(foreground)
    }
}
