import SwiftUI

struct NewTabChoices: View {
    @Environment(CoreClient.self) private var client
    @Environment(HarnessModelCatalog.self) private var harnessCatalog
    let workflowID: UInt64
    let availableHeight: CGFloat
    let isSelected: Bool
    let choose: (WorkflowChoice) -> Void
    /// Starts the harness in the draft's folder, waiting for the user. Throws the reason it couldn't start.
    let startAgent: (HarnessChoice) async throws -> Void
    /// Gives the keyboard back to the terminal, which nothing else in the card can take.
    let focusTerminal: () -> Void
    var createWorkflow: (CoreWorkflowType?) -> Void = { _ in }
    @State private var showsDesigner = false
    @State private var contentHeight: CGFloat = 0
    @State private var startFailure: String?
    @State private var pendingDeletion: CoreWorkflowType?
    @State private var isDeleting = false
    @State private var deletionFailure: String?
    @Binding var selectedType: CoreWorkflowType?
    /// Set while a picked harness starts, so keys typed meanwhile can't turn the draft into a shell.
    @Binding var startingHarness: CoreHarness?
    /// The harness whose unlisted model is being typed, for Single agent's "Other model…".
    @State private var customModelHarness: CoreHarness?
    /// Single agent's last YOLO setting, kept for the next start.
    @AppStorage("singleAgentYolo") private var singleAgentYolo = false
    private var catalog: [CoreWorkflowType] { client.snapshot?.workflowTypes ?? [] }

    // A launch form owns keyboard input, so it can use the space reserved for the shell prompt.
    private var showsPrompt: Bool { selectedType != nil }
    private var promptClearance: CGFloat { showsPrompt ? 0 : NewTabLayout.promptClearance }

    private var verticalPadding: CGFloat {
        return min(
            NewTabLayout.padding,
            max(0, (availableHeight - promptClearance - NewTabLayout.minimumChoiceViewportHeight) / 2))
    }

    private var viewportHeight: CGFloat {
        min(contentHeight, max(0, availableHeight - promptClearance - 2 * verticalPadding))
    }

    private var verticalOffset: CGFloat {
        max(0, promptClearance - (availableHeight - viewportHeight - 2 * verticalPadding) / 2)
    }

    var body: some View {
        ScrollView {
            if let selectedType {
                WorkflowLaunchForm(
                    workflowID: workflowID, type: selectedType, isSelected: isSelected,
                    edit: { createWorkflow(selectedType) },
                    back: {
                        self.selectedType = nil
                        focusTerminal()
                    }
                )
                .id(selectedType.id)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { contentHeight = $0 })
            } else {
                choices
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { contentHeight = $0 })
            }
        }
        // Short forms keep the prompt and actions visible; their introductory text can scroll.
        .defaultScrollAnchor(showsPrompt ? .bottom : .top)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: viewportHeight)
        .padding(.horizontal, NewTabLayout.padding)
        .padding(.vertical, verticalPadding)
        .background(.workflowChoicesBackground, in: .rect(cornerRadius: CornerRadius.choicesCard))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.choicesCard)
                .stroke(.hairline, lineWidth: Surface.hairlineWidth)
        }
        .overlay(alignment: .topTrailing) {
            Button("Close", systemImage: "xmark") { choose(.terminal) }
                .disabled(startingHarness != nil)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Close and use Terminal")
                .padding(NewTabLayout.closePadding)
                .accessibilityIdentifier("closeNewTabChoices")
        }
        .onChange(of: showsDesigner) { _, value in
            if value {
                createWorkflow(nil)
                showsDesigner = false
            }
        }
        .focusedSceneValue(
            \.newWorkflowType, isSelected && !showsPrompt && startingHarness == nil ? $showsDesigner : nil
        )
        .accessibilityIdentifier("newTabChoices")
        .offset(y: verticalOffset)
        .task(id: client.snapshot?.folders.openFolder) { await harnessCatalog.load(using: client) }
        .alert(
            "Delete Workflow?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                guard let type = pendingDeletion else { return }
                pendingDeletion = nil
                deleteWorkflow(type)
            }
            .accessibilityIdentifier("confirmWorkflowDeletion")
        } message: {
            Text(
                """
                Delete “\(pendingDeletion?.definition.name ?? "")” from Your workflows?
                Existing runs keep their saved graph.
                """
            )
        }
        .alert(
            "Could Not Delete Workflow",
            isPresented: Binding(get: { deletionFailure != nil }, set: { if !$0 { deletionFailure = nil } })
        ) {
            Button("OK") { deletionFailure = nil }
        } message: {
            Text(deletionFailure ?? "")
        }
        .sheet(item: $customModelHarness) { harness in
            VStack(alignment: .leading, spacing: 0) {
                Text("\(harness.displayName) model").font(.headline).padding([.top, .horizontal], 12)
                CustomModelForm(
                    action: "Start",
                    efforts: harnessCatalog.entry(for: harness, folder: client.snapshot?.folders.openFolder).models?
                        .efforts ?? []
                ) { model, effort in
                    customModelHarness = nil
                    start(.init(harness: harness, model: model, effort: effort, yolo: singleAgentYolo))
                }
            }
            .appZoom()
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: NewTabLayout.sectionSpacing) {
            ChoicesHeading(
                title: "Choose a workflow", message: "Pick a workflow, or start typing to use Terminal.")
            if let startFailure {
                Label(startFailure, systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.statusNeedsAttention)
                    .accessibilityIdentifier("agentStartFailure")
            }

            Text("Built-in").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                quickChoices
                typeChoices(catalog.filter { $0.reference.builtin != nil })
            }
            Text("Your workflows").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            let custom = catalog.filter { $0.reference.user != nil }
            if custom.isEmpty {
                Text("Create a workflow to add it here.").font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) { typeChoices(custom) }
            }
            Divider()
            HStack {
                Spacer()
                Button("Create your own…") { showsDesigner = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isSelected || startingHarness != nil)
                    .help("Create a workflow (⌥⌘N)")
                    .accessibilityIdentifier("workflowCreateOwn")
            }

        }
    }

    private func typeChoices(_ types: [CoreWorkflowType]) -> some View {
        ForEach(types) { type in
            WorkflowTypeChoiceTile(
                type: type, choose: { selectedType = type },
                delete: type.reference.user == nil ? nil : { pendingDeletion = type }
            )
            .disabled(isDeleting || startingHarness != nil || !isSelected)
        }
    }

    private func deleteWorkflow(_ type: CoreWorkflowType) {
        guard !isDeleting else { return }
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do {
                let result = try await client.sendAndAwaitCompletion(
                    .deleteWorkflowType(reference: type.reference, expectedDefinition: type.definition))
                guard case .workflowTypeDeleted = result else { throw CoreFailure.unexpectedCommandResult }
            } catch CoreFailure.commandRejected(_, let message) {
                deletionFailure = message
            } catch { deletionFailure = error.localizedDescription }
        }
    }

    private var quickChoices: some View {
        ForEach(WorkflowChoice.allCases) { choice in
            if choice.opensMenu {
                Menu {
                    Toggle("YOLO Mode", isOn: $singleAgentYolo)
                        .help("Skip the agent's permission prompts. pi doesn't ask for permission.")
                        .accessibilityIdentifier("singleAgentYolo")
                    Divider()
                    ForEach(CoreHarness.allCases) { harness in
                        Menu(harness.displayName) {
                            SingleAgentHarnessMenu(
                                harness: harness,
                                entry: harnessCatalog.entry(for: harness, folder: client.snapshot?.folders.openFolder),
                                yolo: singleAgentYolo,
                                start: start,
                                chooseCustomModel: { customModelHarness = harness })
                        }
                        .accessibilityIdentifier("harness-\(harness.rawValue)")
                    }
                } label: {
                    ChoiceTile(choice: choice)
                }
                .disabled(startingHarness != nil)
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .help(choice.detail)
                .accessibilityIdentifier("workflowChoice-\(choice.rawValue)")
            } else {
                Button {
                    choose(choice)
                } label: {
                    ChoiceTile(choice: choice)
                }
                .buttonStyle(.plain)
                .help(choice.detail)
                .accessibilityIdentifier("workflowChoice-\(choice.rawValue)")
            }
        }
    }

    private func start(_ choice: HarnessChoice) {
        guard startingHarness == nil else { return }
        startingHarness = choice.harness
        startFailure = nil
        Task {
            defer { startingHarness = nil }
            do { try await startAgent(choice) } catch { startFailure = error.localizedDescription }
        }
    }
}
