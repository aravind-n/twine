import SwiftUI

struct SessionNameForm: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    let save: (String) -> Void
    @State private var name: String

    init(name: String, save: @escaping (String) -> Void) {
        self.save = save
        _name = State(initialValue: name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Session").font(.headline)
            TextField("Session name", text: $name).focused($isFocused).accessibilityIdentifier("sessionName")
                .onSubmit(submit)
            Text("Press Return or ⌘S to rename the session.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 340)
        .onAppear { isFocused = true }
        .focusedSceneValue(
            \.saveAction,
            SaveAction(isEnabled: { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, perform: submit))
    }

    private func submit() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        save(name)
        dismiss()
    }
}
