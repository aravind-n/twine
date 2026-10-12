import Foundation
import OSLog
import SwiftUI

private let sessionLogger = Logger(subsystem: "com.twineproject.Twine", category: "sessions")

struct FolderSidebar: View {
    @Environment(CoreClient.self) private var coreClient
    @Environment(FileTabsModel.self) private var fileTabs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let path: String
    @Bindable var files: FileBrowserModel
    @Bindable var memories: MemoryModel
    @State private var isFilesExpanded = true
    @State private var isSessionsExpanded = true
    @State private var sessionToRename: CoreSession?
    @State private var pendingDeletion: CoreSession?
    @State private var failureMessage: String?

    private var sessions: [CoreSession] {
        coreClient.snapshot?.workflows.sessions.filter { $0.folder == path } ?? []
    }
    private var selectedSession: CoreSession? { coreClient.snapshot?.workflows.session }

    var body: some View {
        GeometryReader { geometry in
            let contentHeight = max(geometry.size.height, SidebarLayout.minimumContentHeight)
            let availableHeight = contentHeight - 3 * SidebarLayout.sectionHeaderHeight - 2
            let expandedCount = (isFilesExpanded ? 1 : 0) + (isSessionsExpanded ? 1 : 0)
            let sectionHeight = availableHeight / CGFloat(max(1, expandedCount))
            ScrollView {
                VStack(spacing: 0) {
                    sectionHeader("Files", isExpanded: $isFilesExpanded) { EmptyView() }
                    SectionViewport(isExpanded: isFilesExpanded && !memories.isExpanded, height: sectionHeight) {
                        FileTree(folder: path, model: files)
                    }
                    Divider().frame(height: 1).padding(.horizontal, SidebarLayout.contentInset)
                    sectionHeader("Sessions", isExpanded: $isSessionsExpanded) {
                        Button(action: create) {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain).help("New Session")
                        .accessibilityLabel("New Session").accessibilityIdentifier("newSession")
                    }
                    SectionViewport(isExpanded: isSessionsExpanded && !memories.isExpanded, height: sectionHeight) {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(sessions) { session in
                                    SessionRow(
                                        session: session,
                                        isSelected: fileTabs.selected == nil && selectedSession?.id == session.id,
                                        select: {
                                            fileTabs.showWorkflows()
                                            run { try await coreClient.selectSession(sessionID: session.id) }
                                        },
                                        rename: { sessionToRename = session }, delete: { pendingDeletion = session })
                                }
                            }
                            .padding(.horizontal, SidebarLayout.contentInset)
                        }
                    }
                    Divider().frame(height: 1).padding(.horizontal, SidebarLayout.contentInset)
                    MemorySidebar(model: memories, folder: path, contentHeight: availableHeight) {
                        guard let source = memories.selected else { return }
                        let request = memories.request(folder: path, sourceID: source.id)
                        Task {
                            do { try await fileTabs.openMemory(request: request, client: coreClient) } catch {
                                memories.openFailure = error.localizedDescription
                            }
                        }
                    }
                }
                .frame(height: contentHeight, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("sidebarViewport")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .sheet(item: $sessionToRename) { session in
            SessionNameForm(name: session.name) { name in
                run { try await coreClient.renameSession(sessionID: session.id, name: name) }
            }
            .appZoom()
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

    private func sectionHeader<Actions: View>(
        _ title: String, isExpanded: Binding<Bool>, @ViewBuilder actions: () -> Actions
    ) -> some View {
        let expanded = isExpanded.wrappedValue && !memories.isExpanded
        return HStack {
            Button {
                withAnimation(reduceMotion ? nil : Motion.sectionToggle) {
                    if memories.isExpanded {
                        memories.isExpanded = false
                        isExpanded.wrappedValue = true
                    } else {
                        isExpanded.wrappedValue.toggle()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title).sidebarSectionLabelStyle()
                    Spacer(minLength: 0)
                }
                .frame(height: SidebarLayout.sectionHeaderHeight).contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("sidebarSection-\(title.lowercased())")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .help("\(expanded ? "Collapse" : "Expand") \(title)")
            actions()
        }
        .frame(height: SidebarLayout.sectionHeaderHeight)
        .padding(.horizontal, SidebarLayout.sectionHeaderPadding)
    }

    private func create() {
        let name = "Session \(sessions.count + 1)"
        run {
            _ = try await coreClient.createSession(folder: path, name: name)
            withAnimation(reduceMotion ? nil : Motion.sectionToggle) {
                isSessionsExpanded = true
                memories.isExpanded = false
            }
            fileTabs.showWorkflows()
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await operation() } catch {
                failureMessage = error.localizedDescription
                sessionLogger.error("Could not update session: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
