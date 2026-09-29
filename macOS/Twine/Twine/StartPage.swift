import Foundation
import SwiftUI

/// The window content when no folder is open: an Open Folder button and the recent folders.
struct StartPage: View {
    let folders: BridgeFolderState
    let chooseFolder: () -> Void
    let openFolder: (String) -> Void
    let removeRecentFolder: (String) -> Void

    var body: some View {
        // Centers the content with a minimum height rather than `defaultScrollAnchor(.center, for:
        // .alignment)`, which centers it with a top inset that macOS draws as a large scroll edge
        // effect over the top of the page.
        GeometryReader { geometry in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Image(systemName: Symbol.app)
                .font(.system(size: 29, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 62, height: 62)
                .glassEffect(in: .rect(cornerRadius: CornerRadius.appIconTile))
                .padding(.bottom, 27)
            Text("Welcome to Twine")
                .startPageTitleStyle()
                .padding(.bottom, 9)
            subtitle
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 28)
            Button(action: chooseFolder) {
                Label("Open Folder…", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            Divider()
                .padding(.top, 35)
            recentFolders
                .padding(.top, 22)
        }
        .frame(maxWidth: 560)
        .padding(44)
    }

    /// Explains why the start page is showing when a folder couldn't be opened.
    @ViewBuilder private var subtitle: some View {
        if let folder = folders.unavailableFolder {
            let name = URL(filePath: folder.path).lastPathComponent
            Label {
                switch folder.reason {
                case .missing:
                    Text("Twine couldn't open “\(name)” because it can't be found.")
                case .inaccessible:
                    Text("Twine couldn't open “\(name)” because it can't be accessed.")
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.statusNeedsAttention)
            }
            .help((folder.path as NSString).abbreviatingWithTildeInPath)
        } else {
            Text("Open a folder to start working with your agents.")
        }
    }

    private var recentFolders: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Recent Folders")
                .font(.headline)
            if folders.recentFolders.isEmpty {
                Text("Folders you open appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .padding(.horizontal, 18)
                    .startPageCard(cornerRadius: CornerRadius.emptyRecentsCard)
            } else {
                VStack(spacing: 4) {
                    ForEach(folders.recentFolders) { folder in
                        RecentFolderCard(
                            folder: folder,
                            open: { openFolder(folder.path) },
                            remove: { removeRecentFolder(folder.path) }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A recent folder that opens when clicked. A missing folder is marked and has a remove button.
private struct RecentFolderCard: View {
    let folder: BridgeRecentFolder
    let open: () -> Void
    let remove: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 0) {
                Image(systemName: folder.isMissing ? "questionmark.folder" : "folder.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(folder.isMissing ? .secondary : Color.folderIcon)
                    .frame(width: 26, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(filePath: folder.path).lastPathComponent)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(folder.isMissing ? .secondary : .primary)
                    HStack(spacing: 4) {
                        if folder.isMissing {
                            Text("Missing")
                                .foregroundStyle(.statusNeedsAttention)
                        }
                        Text((folder.path as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                }
                .lineLimit(1)
                Spacer(minLength: 12)
                if !folder.isMissing {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 15)
            .frame(height: 57)
            .startPageCard(cornerRadius: CornerRadius.recentFolderCard)
            .contentShape(.rect(cornerRadius: CornerRadius.recentFolderCard))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if folder.isMissing {
                Button("Remove from Recent Folders", systemImage: "xmark.circle.fill", action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove from Recent Folders")
                    .padding(.trailing, 15)
            }
        }
        .contextMenu {
            Button("Remove from Recent Folders", action: remove)
        }
    }
}

extension View {
    /// A start page card on the secondary surface. It has the panel hairline too, because on
    /// macOS 26 the secondary surface is the same color as the window background.
    fileprivate func startPageCard(cornerRadius: CGFloat) -> some View {
        background(.secondarySurface, in: .rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.hairline, lineWidth: Surface.hairlineWidth)
            }
    }
}

#if DEBUG
    private let previewFolders = BridgeFolderState(
        openFolder: nil,
        recentFolders: [
            BridgeRecentFolder(path: NSHomeDirectory() + "/Developer/twine", isMissing: false),
            BridgeRecentFolder(path: NSHomeDirectory() + "/Developer/agents-playground", isMissing: false),
            BridgeRecentFolder(path: "/Volumes/Archive/2025/prototype", isMissing: true),
        ],
        unavailableFolder: BridgeUnavailableFolder(path: "/Volumes/Archive/2025/prototype", reason: .missing)
    )

    #Preview("Recent folders") {
        StartPage(folders: previewFolders, chooseFolder: {}, openFolder: { _ in }, removeRecentFolder: { _ in })
            .frame(width: 720, height: 720)
    }

    #Preview("First launch") {
        StartPage(
            folders: BridgeFolderState(openFolder: nil, recentFolders: [], unavailableFolder: nil),
            chooseFolder: {},
            openFolder: { _ in },
            removeRecentFolder: { _ in }
        )
        .frame(width: 720, height: 560)
    }
#endif
