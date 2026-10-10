import SwiftUI

struct MemorySourceList: View {
    @Bindable var model: MemoryModel
    var folder: String?

    var body: some View {
        if model.state == .loading && model.catalog == nil {
            ProgressView("Discovering local memories…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.filteredSources.isEmpty {
            ContentUnavailableView(
                "No Matching Sources", systemImage: "brain",
                description: Text("Choose another filter or inspect the checked locations."))
        } else {
            ScrollViewReader { proxy in
                List(selection: $model.selectedID) {
                    ForEach(MemoryScope.allCases) { scope in
                        let sources = model.filteredSources.filter { $0.scope == scope }
                        if !sources.isEmpty { scopeGroup(scope, sources: sources) }
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden)
                    .background(MemoryPalette.surface)
                    .accessibilityIdentifier("memorySources")
                    .onKeyPress(.return) {
                        model.pane = .reader
                        return .handled
                    }
                    .onChange(of: model.selectedID, initial: true) {
                        if let selected = model.selectedID { proxy.scrollTo(selected, anchor: .center) }
                    }
            }
        }
    }

    private func scopeGroup(_ scope: MemoryScope, sources: [CoreMemorySource]) -> some View {
        DisclosureGroup(isExpanded: expansion(scope)) {
            ForEach(MemoryHarness.allCases) { harness in
                let items = sources.filter { $0.harness == harness }
                if !items.isEmpty {
                    Text(harness.title.uppercased())
                        .font(.system(size: 9, weight: .semibold)).tracking(1)
                        .foregroundStyle(.secondary).padding(.top, 5)
                        .listRowSeparator(.hidden)
                    if scope == .otherFolder {
                        ForEach(Array(Set(items.map(\.group))).sorted(), id: \.self) { group in
                            Text(storageTitle(group)).font(.caption).foregroundStyle(.secondary)
                                .listRowSeparator(.hidden).help(group)
                            rows(items.filter { $0.group == group })
                        }
                    } else {
                        rows(items)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(scope.title).fontWeight(.semibold)
                Text("· \(sources.count)").foregroundStyle(.secondary)
            }.font(.system(size: 12))
        }
        .listRowSeparator(.hidden)
    }

    private func rows(_ sources: [CoreMemorySource]) -> some View {
        ForEach(sources) { source in
            MemorySourceRow(source: source, folder: folder).tag(source.id).id(source.id)
                .listRowSeparator(.hidden)
                .onTapGesture { model.select(source) }
        }
    }

    private func expansion(_ scope: MemoryScope) -> Binding<Bool> {
        Binding(
            get: { model.expandedScopes.contains(scope) },
            set: {
                if $0 { model.expandedScopes.insert(scope) } else { model.expandedScopes.remove(scope) }
            })
    }

    private func storageTitle(_ group: String) -> String {
        if group.hasPrefix("Claude folder: ") {
            let key = String(group.dropFirst("Claude folder: ".count))
            let homeKey = NSHomeDirectory().replacingOccurrences(of: "/", with: "-") + "-workspaces-"
            return key.hasPrefix(homeKey) ? String(key.dropFirst(homeKey.count)) : key
        }
        return group.replacingOccurrences(of: "Codex SQLite: ", with: "SQLite · ")
            .replacingOccurrences(of: "Codex ", with: "").replacingOccurrences(of: "Claude ", with: "")
    }
}

#Preview { MemoryViewPreview() }
