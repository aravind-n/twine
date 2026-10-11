import SwiftUI

struct MemoryFilters: View {
    @Bindable var model: MemoryModel

    var body: some View {
        VStack(spacing: 7) {
            TextField("Search memories…", text: $model.query)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("memorySearch")
            HStack(spacing: 6) {
                Picker("Harness", selection: $model.harness) {
                    Text("Both harnesses").tag(Optional<MemoryHarness>.none)
                    ForEach(MemoryHarness.allCases) { Text($0.title).tag(Optional($0)) }
                }.labelsHidden().accessibilityIdentifier("memoryHarness")
                Picker("Kind", selection: $model.kind) {
                    Text("All kinds").tag(Optional<MemoryKind>.none)
                    ForEach(MemoryKind.allCases) { Text($0.title).tag(Optional($0)) }
                }.labelsHidden().accessibilityIdentifier("memoryKind")
            }
            if model.scope == .otherFolder {
                Picker("Other workspace", selection: $model.group) {
                    Text("All workspaces").tag(Optional<String>.none)
                    ForEach(model.groups, id: \.group) { Text($0.groupTitle).tag(Optional($0.group)) }
                }.labelsHidden().accessibilityIdentifier("memoryWorkspace")
                    .help(model.group ?? "Sources from all other local workspaces")
            }
        }.controlSize(.small).padding(.horizontal, 12).padding(.bottom, 8)
    }
}

#Preview { MemoryViewPreview() }
