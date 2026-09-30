import AppKit
import Foundation
import OSLog
import SwiftUI

private let sessionLogger = Logger(subsystem: "com.twineproject.Twine", category: "sessions")

struct FolderSidebar: View {
    @Environment(CoreClient.self) private var coreClient
    @Environment(FileEditorModel.self) private var fileEditor
    let path: String
    @Bindable var files: FileBrowserModel
    @State private var editor: SessionEditor?
    @State private var pendingDeletion: CoreSession?
    @State private var failureMessage: String?

    private var sessions: [CoreSession] {
        coreClient.snapshot?.workflows.sessions.filter { $0.folder == path } ?? []
    }
    private var selectedSession: CoreSession? { coreClient.snapshot?.workflows.session }

    var body: some View {
        VStack(spacing: 0) {
            folderHeader
            sectionHeader("Files") {
                Button("Collapse All", systemImage: "arrow.up.left.and.arrow.down.right") { files.expanded.removeAll() }
            }
            FileTree(folder: path, model: files)
            Divider().padding(.horizontal, SidebarLayout.folderHeaderInset)
            sectionHeader("Sessions") {
                Button("New Session", systemImage: "plus") { create() }
                    .accessibilityIdentifier("newSession")
                if let selectedSession {
                    Divider()
                    Button("Rename Session", systemImage: "pencil") { rename(selectedSession) }
                    Button("Delete Session", systemImage: "trash", role: .destructive) {
                        pendingDeletion = selectedSession
                    }
                }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sessions) { session in sessionRow(session) }
                    if sessions.isEmpty {
                        Button("New Session", systemImage: "plus") { create() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, SidebarLayout.rowInset)
                            .frame(height: SidebarLayout.rowHeight)
                    }
                }
                .padding(.horizontal, SidebarLayout.folderHeaderInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { SidebarMaterial().ignoresSafeArea() }
        .sheet(item: $editor) { editor in
            SessionNameForm(editor: editor) { name in
                run {
                    if let sessionID = editor.sessionID {
                        try await coreClient.renameSession(sessionID: sessionID, name: name)
                    } else {
                        _ = try await coreClient.createSession(folder: path, name: name)
                    }
                }
            }
        }
        .alert(
            "Delete Session?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                guard let session = pendingDeletion else { return }
                pendingDeletion = nil
                run { try await coreClient.deleteSession(sessionID: session.id) }
            }
        } message: {
            Text("Deleting “\(pendingDeletion?.name ?? "")” stops its shells and removes its workflows.")
        }
        .alert(
            "Session Couldn't Be Updated",
            isPresented: Binding(get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } })
        ) {
            Button("OK") { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
        }
    }

    private var folderHeader: some View {
        HStack {
            Image(systemName: Symbol.app).foregroundStyle(.tint).accessibilityHidden(true)
            Text(URL(filePath: path).lastPathComponent)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("sidebarFolderName")
        }
        .padding(.horizontal, SidebarLayout.folderHeaderInset)
        .frame(height: SidebarLayout.folderHeaderHeight)
        .background(.quaternary, in: .rect(cornerRadius: CornerRadius.sidebarFolderHeader))
        .padding(SidebarLayout.folderHeaderInset)
        .help((path as NSString).abbreviatingWithTildeInPath)
    }

    private func sectionHeader<Actions: View>(_ title: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack {
            Text(title).sidebarSectionLabelStyle()
            Spacer()
            Menu(content: actions) {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 26, height: 26)
            .accessibilityLabel("\(title) Actions")
            .accessibilityIdentifier("\(title.lowercased())Actions")
        }
        .frame(height: SidebarLayout.sectionHeaderHeight)
        .padding(.horizontal, SidebarLayout.sectionHeaderPadding)
    }

    private func sessionRow(_ session: CoreSession) -> some View {
        let selected = selectedSession?.id == session.id
        return Button {
            guard fileEditor.select(nil) else { return }
            run { try await coreClient.selectSession(sessionID: session.id) }
        } label: {
            HStack(spacing: 4) {
                Color.clear.frame(width: 11)
                Image(systemName: "rectangle.stack").frame(width: 16).foregroundStyle(.secondary).accessibilityHidden(
                    true)
                Text(session.name).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: SidebarLayout.rowFontSize, weight: selected ? .medium : .regular))
            .padding(.horizontal, SidebarLayout.rowInset)
            .frame(height: SidebarLayout.rowHeight)
            .contentShape(.rect)
            .background(selected ? Color.fileSelection : .clear, in: .rect(cornerRadius: CornerRadius.fileRowSelection))
        }
        .buttonStyle(.plain)
        .help(session.name)
        .accessibilityIdentifier("sessionRow-\(session.id)")
        .accessibilityValue(selected ? "Selected" : "")
        .contextMenu {
            Button("Rename Session", systemImage: "pencil") { rename(session) }
            Button("Delete Session", systemImage: "trash", role: .destructive) { pendingDeletion = session }
        }
    }

    private func create() { editor = SessionEditor(sessionID: nil, name: "Session \(sessions.count + 1)") }
    private func rename(_ session: CoreSession) { editor = SessionEditor(sessionID: session.id, name: session.name) }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await operation() } catch {
                failureMessage = error.localizedDescription
                sessionLogger.error("Could not update session: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct SessionEditor: Identifiable {
    let id = UUID()
    let sessionID: UInt64?
    let name: String
}

private struct SessionNameForm: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    let editor: SessionEditor
    let save: (String) -> Void
    @State private var name: String

    init(editor: SessionEditor, save: @escaping (String) -> Void) {
        self.editor = editor
        self.save = save
        _name = State(initialValue: editor.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editor.sessionID == nil ? "New Session" : "Rename Session").font(.headline)
            TextField("Session name", text: $name).focused($isFocused).accessibilityIdentifier("sessionName")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("saveSession")
            }
        }
        .padding(24)
        .frame(width: 340)
        .onAppear { isFocused = true }
    }
}
