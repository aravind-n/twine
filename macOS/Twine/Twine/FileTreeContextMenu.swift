import AppKit
import SwiftUI

struct FileTreeContextMenu: View {
    @Environment(FileTabsModel.self) private var tabs
    let entry: FileEntry
    let folder: String
    let isExpanded: Bool
    let toggleExpansion: () -> Void

    private var isDirectory: Bool { entry.kind == .directory }
    private var url: URL { URL(filePath: entry.path) }

    var body: some View {
        if isDirectory {
            Button(isExpanded ? "Collapse Folder" : "Expand Folder", systemImage: "folder", action: toggleExpansion)
        } else {
            Button("Open in Twine", systemImage: "doc.text") {
                tabs.open(path: entry.path, folder: folder)
            }
        }
        Button(isDirectory ? "Open in Finder" : "Open with Default App", systemImage: "arrow.up.forward.app") {
            openExternally()
        }
        Button("Reveal in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        Divider()
        Button("Copy Path", systemImage: "doc.on.doc") { copy(entry.path) }
        Button("Copy Relative Path", systemImage: "doc.on.doc") { copy(entry.relativePath(in: folder)) }
        Button("Copy File Name", systemImage: "doc.on.doc") { copy(entry.name) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openExternally() {
        guard !NSWorkspace.shared.open(url) else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't Open \(entry.name)"
        alert.informativeText = "The item may have moved, or no default app is available to open it."
        alert.runModal()
    }
}

#Preview {
    @Previewable @State var isExpanded = false
    Menu("File Actions") {
        FileTreeContextMenu(
            entry: FileEntry(path: "/tmp", name: "tmp", kind: .directory),
            folder: "/tmp", isExpanded: isExpanded, toggleExpansion: { isExpanded.toggle() })
    }
    .environment(FileTabsModel())
}
