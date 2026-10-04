import SwiftUI

extension CoreHarnessModels {
    func name(of model: String) -> String {
        models.first { $0.id == model }?.name ?? model
    }
}

extension HarnessChoice {
    /// A new harness starts from its own defaults: another harness's model or level means nothing to it.
    mutating func switchHarness(to harness: CoreHarness) {
        guard harness != self.harness else { return }
        self = HarnessChoice(harness: harness, yolo: yolo)
    }

    /// Drops a model the harness no longer lists, unless it takes typed names, then any effort level
    /// the remaining model doesn't support. Without a list, the choice is left for the core to check.
    mutating func fit(to models: CoreHarnessModels?) {
        guard let models else { return }
        if let model, !models.allowsCustom, !models.models.contains(where: { $0.id == model }) {
            self.model = nil
        }
        if let effort, !models.efforts(for: model).contains(effort) { self.effort = nil }
        if !models.supportsYolo { yolo = false }
    }
}

/// A role instance's harness, model, effort, and YOLO controls in the workflow launch form.
struct HarnessChoiceRow: View {
    @Environment(HarnessModelCatalog.self) private var catalog
    @Environment(CoreClient.self) private var client
    let title: String
    let symbol: String
    let color: Color
    @Binding var choice: HarnessChoice
    let identifier: String
    @State private var showsCustomModel = false

    private var entry: HarnessModelCatalog.Entry {
        catalog.entry(for: choice.harness, folder: client.snapshot?.folders.openFolder)
    }

    var body: some View {
        // One line when the card is wide, then the label above the controls, then two control lines.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NewTabLayout.spacing) {
                roleLabel
                harnessPicker
                modelMenu
                effortPicker
                yoloToggle
            }
            VStack(alignment: .leading, spacing: NewTabLayout.choiceTextSpacing) {
                roleLabel
                HStack(spacing: NewTabLayout.spacing) {
                    harnessPicker
                    modelMenu
                    effortPicker
                    yoloToggle
                }
            }
            VStack(alignment: .leading, spacing: NewTabLayout.choiceTextSpacing) {
                roleLabel
                HStack(spacing: NewTabLayout.spacing) {
                    harnessPicker
                    modelMenu
                }
                HStack(spacing: NewTabLayout.spacing) {
                    effortPicker
                    yoloToggle
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A restored choice, or one made before the list loaded, is checked once the list arrives.
        .onChange(of: entry, initial: true) { choice.fit(to: entry.models) }
        .onChange(of: choice.model) { choice.fit(to: entry.models) }
    }

    private var roleLabel: some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(minWidth: 90, alignment: .leading)
    }

    private var harnessPicker: some View {
        Picker(title, selection: Binding(get: { choice.harness }, set: { choice.switchHarness(to: $0) })) {
            ForEach(CoreHarness.allCases) { Text($0.displayName).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("roleHarness-\(identifier)")
    }

    private var modelTitle: String {
        guard let model = choice.model else { return "Default model" }
        return entry.models?.name(of: model) ?? model
    }

    private var modelMenu: some View {
        Menu {
            modelItem("Default model", model: nil)
            switch entry {
            case .loading:
                Text("Loading models…")
            case .failed(let message):
                Text(message)
            case .listed(let listed):
                Divider()
                ForEach(listed.groups) { group in
                    if let title = group.title {
                        Menu(title) {
                            ForEach(group.models) { modelItem($0.name, model: $0.id) }
                        }
                    } else {
                        ForEach(group.models) { modelItem($0.name, model: $0.id) }
                    }
                }
                if listed.models.allowsCustom {
                    Divider()
                    Button("Other…") { showsCustomModel = true }
                }
            }
        } label: {
            Text(modelTitle).lineLimit(1)
        }
        .fixedSize()
        .help(choice.model ?? "The harness's default model")
        .accessibilityIdentifier("roleModel-\(identifier)")
        .popover(isPresented: $showsCustomModel) {
            CustomModelForm(action: "Use") { model, _ in
                choice.model = model
                showsCustomModel = false
            }
            .appZoom()
        }
    }

    /// A checkmarked menu item for one model, so a single selection spans every submenu.
    private func modelItem(_ title: String, model: String?) -> some View {
        Toggle(title, isOn: Binding(get: { choice.model == model }, set: { if $0 { choice.model = model } }))
    }

    @ViewBuilder private var effortPicker: some View {
        let efforts = entry.models?.efforts(for: choice.model) ?? []
        if !efforts.isEmpty {
            Picker("Effort", selection: $choice.effort) {
                Text("Default effort").tag(String?.none)
                ForEach(efforts, id: \.self) { Text($0.capitalized).tag(Optional($0)) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("roleEffort-\(identifier)")
        }
    }

    private var yoloToggle: some View {
        let supported = entry.models?.supportsYolo ?? (choice.harness != .piAgent && choice.harness != .opencode)
        return Toggle("YOLO", isOn: $choice.yolo)
            .toggleStyle(.checkbox)
            .disabled(!supported)
            .help(
                supported
                    ? "Skip \(choice.harness.displayName)'s permission prompts"
                    : (choice.harness == .opencode
                        ? "OpenCode's interactive interface has no option to skip permission prompts"
                        : "\(choice.harness.displayName) doesn't ask for permission")
            )
            .accessibilityIdentifier("roleYolo-\(identifier)")
    }
}

/// One harness's items in the Single agent menu: a submenu per model, whose effort levels start it.
struct SingleAgentHarnessMenu: View {
    let harness: CoreHarness
    let entry: HarnessModelCatalog.Entry
    let yolo: Bool
    let start: (HarnessChoice) -> Void
    let chooseCustomModel: () -> Void

    var body: some View {
        startItem("Default model", model: nil)
        switch entry {
        case .loading:
            Text("Loading models…")
        case .failed(let message):
            Text(message)
        case .listed(let listed):
            Divider()
            ForEach(listed.groups) { group in
                if let title = group.title {
                    Menu(title) {
                        ForEach(group.models) { startItem($0.name, model: $0) }
                    }
                } else {
                    ForEach(group.models) { startItem($0.name, model: $0) }
                }
            }
            if listed.models.allowsCustom {
                Divider()
                Button("Other model…", action: chooseCustomModel)
            }
        }
    }

    /// Starts the harness with `model`, or offers its effort levels first when it has them.
    @ViewBuilder private func startItem(_ title: String, model: CoreHarnessModel?) -> some View {
        let efforts = entry.listed?.efforts(for: model) ?? []
        let choice = HarnessChoice(
            harness: harness, model: model?.id, yolo: yolo && entry.models?.supportsYolo != false)
        if efforts.isEmpty {
            Button(title) { start(choice) }
        } else {
            Menu(title) {
                Button("Default effort") { start(choice) }
                Divider()
                ForEach(efforts, id: \.self) { effort in
                    Button(effort.capitalized) {
                        var choice = choice
                        choice.effort = effort
                        start(choice)
                    }
                }
            }
        }
    }
}

/// Asks for a model name the harness didn't list, such as a specific dated model ID, and its effort
/// level when `efforts` offers any.
struct CustomModelForm: View {
    @Environment(\.dismiss) private var dismiss
    let action: String
    var efforts: [String] = []
    let submit: (String, String?) -> Void
    @State private var model = ""
    @State private var effort: String?
    @FocusState private var isFocused: Bool

    private var trimmed: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The core rejects names that could read as a flag or span words, so catch them here first.
    private var isValid: Bool {
        !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.contains(where: \.isWhitespace)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NewTabLayout.spacing) {
            Text("Model name").font(.caption.weight(.semibold))
            TextField("Full model name", text: $model)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .focused($isFocused)
                .onSubmit { if isValid { submit(trimmed, effort) } }
                .accessibilityIdentifier("customModel")
            HStack {
                if !efforts.isEmpty {
                    Picker("Effort", selection: $effort) {
                        Text("Default effort").tag(String?.none)
                        ForEach(efforts, id: \.self) { Text($0.capitalized).tag(Optional($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action) { submit(trimmed, effort) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .controlSize(.small)
        }
        .padding(12)
        .onAppear { isFocused = true }
    }
}
