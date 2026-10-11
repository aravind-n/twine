import SwiftUI
import TwineSyntax

struct FileViewer: View {
    @Environment(CoreClient.self) private var coreClient
    @Environment(FileEditorModel.self) private var editor
    let path: String
    let folder: String
    let failure: String?
    let isVisible: Bool
    let openFile: (URL) -> Void
    var didSave: (() async throws -> Void)?
    @State private var showsGoToLine = false
    @State private var line = "1"
    @State private var lineRequest: FileLineRequest?
    @State private var mode = Mode.preview
    @State private var syntaxMode = FileSyntaxMode.automatic

    private var current: FilePreview? { editor.baseline }
    private var previewFormat: FilePreviewFormat? { editor.previewFormat }
    private var showsPreview: Bool { previewFormat != nil && mode == .preview }
    private enum Mode { case preview, source }
    private var syntaxLanguage: SyntaxLanguage? { syntaxMode.language(path: path, source: editor.text) }
    private var editorSettings: CoreEditorConfig { coreClient.snapshot?.config.editor ?? .init() }
    private var saveStatus: String {
        if !editor.isEditable { return "Read-only" }
        if editor.isSaving { return "Saving…" }
        if editor.isConfigFile || !editor.autosaveSettings.autosave { return "⌘S to save" }
        return editor.autosavePaused ? "Autosave paused · ⌘S to retry" : "Autosave"
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    fileTitle
                    Spacer(minLength: 0)
                    syntaxControls
                    displayControls
                    saveControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    fileTitle
                    if previewFormat != nil || editor.memorySource != nil {
                        HStack(spacing: 10) {
                            displayControls
                            Spacer(minLength: 0)
                        }
                    }
                    HStack(spacing: 10) {
                        syntaxControls
                        saveControls
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(14)
            Divider()
            if let failure, current == nil {
                ContentUnavailableView(
                    "Couldn't Refresh File", systemImage: "exclamationmark.triangle",
                    description: Text(failure))
            } else if let current {
                ZStack {
                    content(current)
                        .opacity(showsPreview ? 0 : 1)
                        .allowsHitTesting(!showsPreview)
                        .accessibilityHidden(showsPreview)
                    if showsPreview {
                        if let diskFile = editor.diskFile {
                            if diskFile.status == .text, let format = previewFormat {
                                HTMLPreview(
                                    file: diskFile, folder: folder, navigationURL: editor.navigationURL,
                                    isVisible: isVisible, openFile: openFile, format: format,
                                    localResourcesOnly: editor.memoryRequest != nil,
                                    hidesFrontmatter: editor.memoryRequest != nil,
                                    focusesOnShow: editor.memoryRequest == nil
                                )
                                .id(editor.navigationID)
                            } else {
                                content(diskFile)
                            }
                        } else {
                            ProgressView("Loading preview…")
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("fileViewport")
            } else {
                ProgressView("Loading file…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(.rect(cornerRadius: CornerRadius.panel))
        .accessibilityElement(children: .contain)
        .onChange(of: editor.navigationID) { mode = .preview }
        .onChange(of: editorSettings, initial: true) { editor.configureAutosave(editorSettings) }
        .task(id: editor.autosaveID) { await editor.autosave() }
        .task(id: editor.saveID) { await editor.savePending(client: coreClient, didSave: didSave) }
        .alert(
            "File Changed on Disk",
            isPresented: Binding(
                get: { isVisible && editor.conflict != nil }, set: { if !$0 { editor.conflict = nil } }),
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
            isPresented: Binding(
                get: { isVisible && editor.failure != nil }, set: { if !$0 { editor.failure = nil } })
        ) {
            Button("OK") { editor.failure = nil }
        } message: {
            Text(editor.failure ?? "")
        }
    }

    private var fileTitle: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(
                editor.memorySource?.title
                    ?? (path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : path)
            )
            .font(.caption).lineLimit(1).truncationMode(.middle).help(path)
        }
    }

    @ViewBuilder private var syntaxControls: some View {
        if current?.status == .text, !showsPreview {
            syntaxMenu
        }
    }

    @ViewBuilder private var displayControls: some View {
        if let format = previewFormat {
            Picker("\(format.name) display", selection: $mode) {
                Text("Preview").tag(Mode.preview)
                Text("Source").tag(Mode.source)
            }
            .pickerStyle(.segmented).fixedSize().controlSize(.small)
            .help("Preview shows the saved file. Source lets you view and edit its \(format.name).")
            .accessibilityIdentifier("\(format.accessibilityPrefix)DisplayMode")
        }
        if let source = editor.memorySource {
            MemorySourceInfo(
                source: source, lineCount: editor.text.components(separatedBy: "\n").count,
                canEdit: editor.isEditable)
        }
    }

    @ViewBuilder private var saveControls: some View {
        if editor.isDirty { Text("Edited").sectionLabelStyle().accessibilityIdentifier("fileEdited") }
        if current?.status == .text {
            Text(saveStatus).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("fileSaveStatus")
                .accessibilityLabel(saveStatus)
                .help("Press ⌘S to save immediately. Configure autosave and its delay in Settings.")
        }
        Button("Go to Line…") { showsGoToLine = true }
            .font(.caption)
            .keyboardShortcut("l", modifiers: .command)
            .disabled(current?.status != .text || showsPreview)
            .accessibilityIdentifier("goToLine")
            .popover(isPresented: $showsGoToLine) { goToLineForm.appZoom() }
    }

    @ViewBuilder private func content(_ preview: FilePreview) -> some View {
        switch preview.status {
        case .text:
            FileTextView(
                text: Binding(get: { editor.text }, set: { editor.text = $0 }),
                loadID: editor.loadID, isEditable: editor.isEditable && !showsPreview,
                isVisible: isVisible && !showsPreview, lineRequest: lineRequest, language: syntaxLanguage,
                focusesOnShow: editor.memoryRequest == nil || previewFormat != nil)
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

    private var syntaxMenu: some View {
        Menu {
            Picker("Syntax language", selection: $syntaxMode) {
                Text("Automatic").tag(FileSyntaxMode.automatic)
                Text("Plain Text").tag(FileSyntaxMode.plainText)
                Divider()
                ForEach(SyntaxLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(FileSyntaxMode.language(language))
                }
            }
        } label: {
            Text(syntaxLanguage?.displayName ?? "Plain Text")
                .font(.caption)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Choose the language used for syntax highlighting.")
        .accessibilityIdentifier("fileSyntaxLanguage")
        .accessibilityLabel("Syntax language")
        .accessibilityValue(syntaxLanguage?.displayName ?? "Plain Text")
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
