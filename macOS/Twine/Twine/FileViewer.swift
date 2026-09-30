import SwiftUI

struct FileViewer: View {
    @Environment(BridgeClient.self) private var bridgeClient
    @Environment(FileEditorModel.self) private var editor
    let path: String
    let folder: String
    let failure: String?
    let close: () -> Void
    @State private var showsGoToLine = false
    @State private var line = "1"
    @State private var lineRequest: FileLineRequest?

    private var current: FilePreview? { editor.baseline }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : path)
                    .font(.caption).lineLimit(1).truncationMode(.middle).help(path)
                Spacer(minLength: 0)
                if editor.isDirty { Text("Edited").sectionLabelStyle().accessibilityIdentifier("fileEdited") }
                Button(editor.isSaving ? "Saving…" : "Save") { editor.requestSave() }
                    .font(.caption).disabled(!editor.canSave).accessibilityIdentifier("saveFile")
                Button("Go to Line…") { showsGoToLine = true }
                    .font(.caption)
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(current?.status != .text)
                    .accessibilityIdentifier("goToLine")
                    .popover(isPresented: $showsGoToLine) { goToLineForm }
                Button("Close File", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .keyboardShortcut("w", modifiers: .command)
                    .accessibilityIdentifier("closeFile")
            }
            .padding(14)
            Divider()
            if let failure, current == nil {
                ContentUnavailableView(
                    "Couldn't Refresh File", systemImage: "exclamationmark.triangle",
                    description: Text(failure))
            } else if let current {
                content(current)
            } else {
                ProgressView("Loading file…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .clipShape(.rect(cornerRadius: CornerRadius.panel))
        .overlay { RoundedRectangle(cornerRadius: CornerRadius.panel).stroke(.hairline, lineWidth: 1) }
        .task(id: editor.saveID) { await editor.savePending(client: bridgeClient) }
        .alert(
            "File Changed on Disk",
            isPresented: Binding(get: { editor.conflict != nil }, set: { if !$0 { editor.conflict = nil } }),
            presenting: editor.conflict
        ) { file in
            Button("Cancel", role: .cancel) { editor.conflict = nil }
            Button("Reload", role: .destructive) { editor.reloadConflict(file) }
            Button("Overwrite", role: .destructive) { editor.requestSave(overwrite: true) }
        } message: { _ in
            Text(
                "The file changed since you opened it. Reload discards your edits. "
                    + "Overwrite replaces the disk version with your edits."
            )
        }
        .alert(
            "Couldn't Save File",
            isPresented: Binding(get: { editor.failure != nil }, set: { if !$0 { editor.failure = nil } })
        ) {
            Button("OK") { editor.failure = nil }
        } message: {
            Text(editor.failure ?? "")
        }
    }

    @ViewBuilder private func content(_ preview: FilePreview) -> some View {
        switch preview.status {
        case .text:
            FileTextView(
                text: Binding(get: { editor.text }, set: { editor.text = $0 }),
                loadID: editor.loadID, isEditable: !editor.isSaving, lineRequest: lineRequest)
        case .binary:
            unavailable("Binary File", "Only UTF-8 text files can be displayed.")
        case .tooLarge:
            unavailable("File Too Large", "The text viewer supports files up to 2 MiB.")
        case .missing:
            unavailable("File Deleted or Moved", "This path no longer exists. Select a file in the sidebar.")
        case .unsupported:
            unavailable("Preview Unavailable", "Symbolic links and special files are not previewed.")
        case .unavailable:
            unavailable("Couldn't Read File", preview.message ?? "Check the file's permissions.")
        }
    }

    private func unavailable(_ title: String, _ message: String) -> some View {
        ContentUnavailableView(title, systemImage: "doc.questionmark", description: Text(message))
    }

    private var requestedRange: NSRange? {
        guard let number = Int(line), current?.status == .text else { return nil }
        return FileTextView.lineRange(in: editor.text, line: number)
    }

    private var goToLineForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Line").font(.headline)
            TextField("Line number", text: $line).accessibilityIdentifier("lineNumber")
                .onSubmit { goToLine() }
            if requestedRange == nil {
                Text("Enter a line number in this file.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Go", action: goToLine).keyboardShortcut(.defaultAction)
                .disabled(requestedRange == nil).accessibilityIdentifier("confirmGoToLine")
        }.padding(18).frame(width: 240)
    }

    private func goToLine() {
        guard requestedRange != nil, let number = Int(line) else { return }
        lineRequest = FileLineRequest(line: number)
        showsGoToLine = false
    }
}
