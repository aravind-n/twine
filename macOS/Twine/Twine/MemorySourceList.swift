import SwiftUI

struct MemorySourceList: View {
    @Bindable var model: MemoryModel
    let scope: MemoryScope
    let folder: String
    let open: () -> Void
    @State private var scrollID: String?
    @State private var restorationID: String?
    @State private var isRestoring = true
    @FocusState private var hasFocus: Bool

    init(model: MemoryModel, scope: MemoryScope, folder: String, open: @escaping () -> Void) {
        self.model = model
        self.scope = scope
        self.folder = folder
        self.open = open
        _scrollID = State(initialValue: model.scrollID(for: scope) ?? model.selectedID)
        _restorationID = State(initialValue: model.scrollID(for: scope) ?? model.selectedID)
    }

    var body: some View {
        Group {
            if model.state == .loading && model.catalog == nil {
                ProgressView("Finding memories…").controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.filteredSources.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "brain").font(.title2)
                    Text("No matching sources").fontWeight(.medium)
                    Text("Try another location or filter.").foregroundStyle(.secondary)
                }.font(.caption).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                sources
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("memorySources")
    }

    private var sources: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.filteredSources) { source in
                        Button {
                            model.select(source)
                            hasFocus = true
                            open()
                        } label: {
                            MemorySourceRow(source: source, folder: folder)
                                .background(
                                    model.selectedID == source.id ? Color.fileSelection : .clear,
                                    in: .rect(cornerRadius: 6))
                        }.buttonStyle(.plain).id(source.id)
                            .accessibilityIdentifier("memorySource-\(source.id)")
                            .accessibilityAddTraits(model.selectedID == source.id ? [.isSelected] : [])
                    }
                }.scrollTargetLayout().padding(.horizontal, 8)
            }
            .scrollPosition(id: $scrollID, anchor: .top)
            .onChange(of: scrollID) {
                if !isRestoring, model.scope == scope, let scrollID {
                    model.rememberScroll(scrollID, for: scope)
                }
            }
            .task {
                // Lazy rows need a layout pass before an offscreen target can be restored.
                let selection = model.selectedID
                let sources = model.filteredSources.map(\.id)
                let target = sources.contains { $0 == restorationID } ? restorationID : selection
                defer { isRestoring = false }
                await Task.yield()
                guard !Task.isCancelled, model.scope == scope, model.selectedID == selection,
                    model.filteredSources.map(\.id) == sources, let target
                else { return }
                proxy.scrollTo(target, anchor: .top)
            }
            .onChange(of: model.selectedID) {
                if model.scope == scope, let selected = model.selectedID { proxy.scrollTo(selected) }
            }
            .focusable(interactions: .edit).focused($hasFocus).focusEffectDisabled()
            .onKeyPress(.upArrow) {
                moveSelection(-1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveSelection(1)
                return .handled
            }
            .onKeyPress(.space) {
                open()
                return .handled
            }
            .onKeyPress(.return) {
                open()
                return .handled
            }
        }
    }
    private func moveSelection(_ delta: Int) {
        let items = model.filteredSources
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == model.selectedID } ?? 0
        model.select(items[max(0, min(items.count - 1, index + delta))])
        open()
    }

}

#Preview { MemoryViewPreview() }
