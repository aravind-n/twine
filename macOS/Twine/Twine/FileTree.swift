import SwiftUI

struct FileTree: View {
    let folder: String
    @Bindable var model: FileBrowserModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let failure = model.failure {
                    Text(failure).font(.caption).foregroundStyle(.secondary).padding(12)
                }
                FileTreeDirectory(path: folder, depth: 0, model: model)
            }
            .padding(.horizontal, SidebarLayout.folderHeaderInset)
        }
        .accessibilityIdentifier("fileTree")
    }
}

private struct FileTreeDirectory: View {
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
                        FileTreeDirectory(path: entry.path, depth: depth + 1, model: model)
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
        let isDirectory = entry.kind == .directory
        let selected = model.selectedPath == entry.path
        return Button {
            if isDirectory { model.toggle(entry.path) } else { model.selectedPath = entry.path }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.expanded.contains(entry.path) ? "chevron.down" : "chevron.right")
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
                selected ? Color.fileSelection : .clear,
                in: .rect(cornerRadius: CornerRadius.fileRowSelection))
        }
        .buttonStyle(.plain)
        .help(entry.path)
        .accessibilityLabel(entry.name)
        .accessibilityValue(
            isDirectory
                ? (model.expanded.contains(entry.path) ? "Expanded" : "Collapsed")
                : (selected ? "Selected" : "")
        )
        .accessibilityIdentifier("fileRow-\(entry.path)")
    }
}
