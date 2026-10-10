import SwiftUI

struct MemorySourceList: View {
    @Bindable var model: MemoryModel

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
                }.listStyle(.inset).accessibilityIdentifier("memorySources")
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
                if !items.isEmpty { harnessGroup(harness, scope: scope, sources: items) }
            }
        } label: {
            Label(scope.title, systemImage: scope == .global ? "globe" : "folder")
        }
    }

    private func harnessGroup(_ harness: MemoryHarness, scope: MemoryScope, sources: [CoreMemorySource]) -> some View {
        let key = "\(scope.rawValue).\(harness.rawValue)"
        return DisclosureGroup(
            isExpanded: Binding(
                get: { model.expandedHarnesses.contains(key) },
                set: { if $0 { model.expandedHarnesses.insert(key) } else { model.expandedHarnesses.remove(key) } }
            )
        ) {
            ForEach(Array(Set(sources.map(\.group))).sorted(), id: \.self) { group in
                DisclosureGroup(
                    storageTitle(group),
                    isExpanded: Binding(
                        get: { model.expandedGroups.contains(group) },
                        set: {
                            if $0 { model.expandedGroups.insert(group) } else { model.expandedGroups.remove(group) }
                        }
                    )
                ) {
                    ForEach(sources.filter { $0.group == group }) { source in
                        MemorySourceRow(source: source).tag(source.id).id(source.id)
                            .onTapGesture {
                                model.selectedID = source.id
                                model.pane = .reader
                            }
                    }
                }.help(group)
            }
        } label: {
            Label(harness.title, systemImage: harness == .codex ? "terminal" : "bubble.left")
                .foregroundStyle(harness == .codex ? Color.blue : Color.orange)
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
            return "Auto memory · " + (key.hasPrefix(homeKey) ? String(key.dropFirst(homeKey.count)) : key)
        }
        return group.replacingOccurrences(of: "Codex SQLite: ", with: "SQLite · ")
            .replacingOccurrences(of: "Codex ", with: "").replacingOccurrences(of: "Claude ", with: "")
    }
}

#Preview { MemoryViewPreview() }
