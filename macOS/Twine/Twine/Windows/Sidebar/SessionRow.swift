import SwiftUI

struct SessionRow: View {
    let session: CoreSession
    let isSelected: Bool
    let select: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) {
                HStack(spacing: 4) {
                    Color.clear.frame(width: 11)
                    Image(systemName: "rectangle.stack").frame(width: 16).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(session.name).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, SidebarLayout.rowInset)
                .frame(height: SidebarLayout.rowHeight).contentShape(.rect)
            }
            .buttonStyle(.plain).help(session.name)
            .accessibilityLabel(session.name)
            .accessibilityIdentifier("sessionRow-\(session.id)")
            .accessibilityValue(isSelected ? "Selected" : "")
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: SidebarLayout.rowHeight)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: 22, height: SidebarLayout.rowHeight)
            .opacity(isHovered ? 1 : 0).allowsHitTesting(isHovered).accessibilityHidden(!isHovered)
            .accessibilityLabel("Actions for \(session.name)").accessibilityIdentifier("sessionActions-\(session.id)")
        }
        .font(.system(size: SidebarLayout.rowFontSize, weight: isSelected ? .medium : .regular))
        .padding(.trailing, SidebarLayout.rowInset)
        .frame(height: SidebarLayout.rowHeight).contentShape(.rect)
        .background(isSelected ? Color.fileSelection : .clear, in: .rect(cornerRadius: CornerRadius.fileRowSelection))
        .onHover { isHovered = $0 }
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        Button("Rename Session", systemImage: "pencil", action: rename)
        Button("Delete Session", systemImage: "trash", role: .destructive, action: delete)
    }
}
