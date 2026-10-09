import SwiftUI

struct FileTree: View {
    let folder: String
    @Bindable var model: FileBrowserModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                FileTreeRow(
                    entry: FileEntry(path: folder, name: URL(filePath: folder).lastPathComponent, kind: .directory),
                    folder: folder, depth: 0, isExpanded: model.isRootExpanded, action: model.toggleRoot)
                if model.isRootExpanded {
                    if let failure = model.failure {
                        Text(failure).font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                    FileTreeDirectory(folder: folder, path: folder, depth: 1, model: model)
                }
            }
            .padding(.horizontal, SidebarLayout.contentInset)
        }
        .accessibilityIdentifier("fileTree")
    }
}

private struct FileTreeDirectory: View {
    @Environment(FileTabsModel.self) private var tabs
    let folder: String
    let path: String
    let depth: Int
    @Bindable var model: FileBrowserModel

    private var directory: FileDirectory? { model.snapshot?.directories.first { $0.path == path } }

    var body: some View {
        if let directory {
            if let error = directory.error {
                note(error)
            } else if directory.entries.isEmpty {
                note("Empty folder")
            } else {
                ForEach(directory.entries) { entry in
                    row(entry)
                    if entry.kind == .directory && model.expanded.contains(entry.path) {
                        FileTreeDirectory(folder: folder, path: entry.path, depth: depth + 1, model: model)
                    }
                }
            }
        } else {
            note("Loading…")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, SidebarLayout.rowInset + CGFloat(depth) * 15)
            .padding(.vertical, 6)
    }

    private func row(_ entry: FileEntry) -> some View {
        FileTreeRow(
            entry: entry, folder: folder, depth: depth, isExpanded: model.expanded.contains(entry.path),
            isSelected: tabs.selected?.path == entry.path
        ) {
            if entry.kind == .directory {
                model.toggle(entry.path)
            } else {
                tabs.open(path: entry.path, folder: folder)
            }
        }
    }
}

private struct FileTreeRow: View {
    let entry: FileEntry
    let folder: String
    let depth: Int
    let isExpanded: Bool
    var isSelected = false
    let action: () -> Void

    private var isDirectory: Bool { entry.kind == .directory }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .frame(width: 11).opacity(isDirectory ? 1 : 0)
                Image(systemName: isDirectory ? "folder" : (entry.kind == .symlink ? "link" : "doc"))
                    .font(.system(size: 12)).frame(width: 16)
                    .foregroundStyle(isDirectory ? Color.accentColor.opacity(0.8) : .secondary)
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: SidebarLayout.rowFontSize))
            .padding(.leading, SidebarLayout.rowInset + CGFloat(depth) * 15)
            .padding(.trailing, 6)
            .frame(height: SidebarLayout.rowHeight)
            .contentShape(.rect)
            .background(
                isSelected ? Color.fileSelection : .clear,
                in: .rect(cornerRadius: CornerRadius.fileRowSelection))
        }
        .buttonStyle(.plain)
        .help(entry.path)
        .accessibilityLabel(entry.name)
        .accessibilityValue(
            isDirectory
                ? (isExpanded ? "Expanded" : "Collapsed")
                : (isSelected ? "Selected" : "")
        )
        .accessibilityIdentifier("fileRow-\(entry.path)")
        .contextMenu {
            FileTreeContextMenu(entry: entry, folder: folder, isExpanded: isExpanded, toggleExpansion: action)
        }
    }
}
