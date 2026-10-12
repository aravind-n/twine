import AppKit
import SwiftUI

extension CoreWorkflowType.AgentColor {
    var tint: Color {
        let systemColor: NSColor =
            switch self {
            case .blue: .systemBlue
            case .teal: .systemTeal
            case .green: .systemGreen
            case .yellow: .systemYellow
            case .orange: .systemOrange
            case .red: .systemRed
            case .pink: .systemPink
            case .purple: .systemPurple
            }
        return Color(nsColor: systemColor).mix(with: Color(nsColor: .secondaryLabelColor), by: 0.25, in: .device)
    }
}

struct WorkflowAgentColorPicker: View {
    @Binding var color: CoreWorkflowType.AgentColor?

    var body: some View {
        LabeledContent("Color") {
            HStack(spacing: 3) {
                swatch(nil)
                ForEach(CoreWorkflowType.AgentColor.allCases, id: \.self) { swatch($0) }
            }
        }
    }

    private func swatch(_ value: CoreWorkflowType.AgentColor?) -> some View {
        let name = value?.rawValue.capitalized ?? "None"
        return Button {
            color = value
        } label: {
            ZStack {
                if let value {
                    Circle().fill(value.tint).frame(width: 16, height: 16)
                    if color == value {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(checkmarkColor(value))
                    }
                } else {
                    Image(systemName: "circle.slash").font(.system(size: 16))
                        .foregroundStyle(color == nil ? .primary : .secondary)
                }
            }.frame(width: 24, height: 24).contentShape(.circle)
        }.buttonStyle(.plain).help(name)
            .accessibilityLabel("\(name) color")
            .accessibilityValue(color == value ? "Selected" : "")
    }

    private func checkmarkColor(_ value: CoreWorkflowType.AgentColor) -> Color {
        switch value {
        case .teal, .green, .yellow, .orange: .black
        case .blue, .red, .pink, .purple: .white
        }
    }
}

struct WorkflowAgentDefaultsEditor: View {
    @Environment(CoreClient.self) private var client
    @Environment(HarnessModelCatalog.self) private var catalog
    @Binding var role: CoreWorkflowType.Role

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle(
                "Use launch defaults",
                isOn: Binding(
                    get: { role.agentDefaults != nil },
                    set: { role.agentDefaults = $0 ? .init(choice: .init(harness: .codex)) : nil })
            ).toggleStyle(.checkbox)
            if role.agentDefaults != nil {
                HarnessChoiceRow(
                    title: "Agent", symbol: "terminal", color: .secondary,
                    choice: Binding(
                        get: { role.agentDefaults?.choice ?? .init(harness: .codex) },
                        set: { role.agentDefaults = .init(choice: $0) }), identifier: "defaults-\(role.id)",
                    usesInlineCustomModel: true, adaptsChoiceToCatalog: false
                )
                .task(id: client.snapshot?.folders.openFolder) { await catalog.load(using: client) }
            }
            Text(
                role.agentDefaults == nil
                    ? "Choose agent settings when you start this workflow."
                    : "You can change these settings before each run."
            ).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
