import SwiftUI

struct MemoryFilters: View {
    @Bindable var model: MemoryModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                search
                controls
            }
            VStack(alignment: .leading, spacing: 8) {
                search
                controls
            }
            VStack(alignment: .leading, spacing: 8) {
                search
                scope
                harness
                kind
            }
        }.controlSize(.small).padding(.horizontal, 10).padding(.vertical, 8)
            .background(MemoryPalette.surface)
    }

    private var search: some View {
        TextField("Search memories…", text: $model.query)
            .textFieldStyle(.roundedBorder).frame(minWidth: 120)
            .accessibilityIdentifier("memorySearch")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            scope
            harness
            kind
        }.controlSize(.small).fixedSize()
    }

    private var scope: some View {
        Picker("Scope", selection: $model.scope) {
            Text("All scopes").tag(Optional<MemoryScope>.none)
            ForEach(MemoryScope.allCases) { Text($0.title).tag(Optional($0)) }
        }.labelsHidden().accessibilityIdentifier("memoryScope")
    }

    private var harness: some View {
        Picker("Harness", selection: $model.harness) {
            Text("Both harnesses").tag(Optional<MemoryHarness>.none)
            ForEach(MemoryHarness.allCases) { Text($0.title).tag(Optional($0)) }
        }.labelsHidden().accessibilityIdentifier("memoryHarness")
    }

    private var kind: some View {
        Picker("Kind", selection: $model.kind) {
            Text("All kinds").tag(Optional<MemoryKind>.none)
            ForEach(MemoryKind.allCases) { Text($0.title).tag(Optional($0)) }
        }.labelsHidden().accessibilityIdentifier("memoryKind")
    }
}

#Preview { MemoryViewPreview() }
