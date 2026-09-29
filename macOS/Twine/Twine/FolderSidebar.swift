import Foundation
import SwiftUI

/// The folder header; files and sessions will fill the sidebar in TWINE-15.
struct FolderSidebar: View {
    let path: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: Symbol.app)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(URL(filePath: path).lastPathComponent)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("sidebarFolderName")
            }
            .padding(.horizontal, SidebarLayout.folderHeaderInset)
            .frame(height: SidebarLayout.folderHeaderHeight)
            .glassEffect(in: .rect(cornerRadius: CornerRadius.sidebarFolderHeader))
            .padding(SidebarLayout.folderHeaderInset)
            .help((path as NSString).abbreviatingWithTildeInPath)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.windowBackground)
    }
}
