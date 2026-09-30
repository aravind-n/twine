import SwiftUI

struct FileViewer: View {
    let path: String
    let folder: String
    let preview: FilePreview?
    let failure: String?
    let close: () -> Void
    @State private var showsGoToLine = false
    @State private var line = "1"
    @State private var lineRequest: FileLineRequest?

    private var current: FilePreview? { preview?.path == path ? preview : nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : path)
                    .font(.caption).lineLimit(1).truncationMode(.middle).help(path)
                Spacer(minLength: 0)
                Text("Read Only").sectionLabelStyle()
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
            if let failure {
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
    }

    @ViewBuilder private func content(_ preview: FilePreview) -> some View {
        switch preview.status {
        case .text:
            FileTextView(text: preview.text ?? "", lineRequest: lineRequest)
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
        guard let number = Int(line), let text = current?.text else { return nil }
        return FileTextView.lineRange(in: text, line: number)
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
