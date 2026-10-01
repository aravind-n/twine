import Foundation

/// Presentation-only form prefills. The core owns the assignments after a successful launch.
struct WorkflowLaunchPreferences {
    private let defaults: UserDefaults
    private static let key = "workflowRoleHarnesses"
    /// Each instance's model, effort, and YOLO setting, parallel to its harness. Kept apart so older saves still read.
    private static let optionsKey = "workflowRoleModels"

    init(defaults: UserDefaults? = nil) {
        if let defaults {
            self.defaults = defaults
            return
        }
        #if DEBUG
            if let suite = ProcessInfo.processInfo.environment["TWINE_TEST_PREFERENCES_SUITE"] {
                self.defaults = UserDefaults(suiteName: suite) ?? .standard
                return
            }
        #endif
        self.defaults = .standard
    }

    func choices(for type: CoreWorkflowType) -> [String: [HarnessChoice]] {
        let saved = defaults.dictionary(forKey: Self.key)?[type.preferenceKey] as? [String: [String]] ?? [:]
        let options =
            defaults.dictionary(forKey: Self.optionsKey)?[type.preferenceKey] as? [String: [[String: String]]] ?? [:]
        return Dictionary(
            uniqueKeysWithValues: type.definition.roles.map { role in
                let harnesses = (saved[role.id] ?? []).compactMap(CoreHarness.init(rawValue:))
                let roleOptions = options[role.id] ?? []
                let choices = harnesses.indices.map { index in
                    let option = roleOptions.indices.contains(index) ? roleOptions[index] : [:]
                    return HarnessChoice(
                        harness: harnesses[index], model: option["model"], effort: option["effort"],
                        yolo: option["yolo"] == "true")
                }
                let count = min(role.instances.max, max(role.instances.min, choices.count))
                let fill = choices.last ?? HarnessChoice(harness: .codex)
                let bounded =
                    Array(choices.prefix(count)) + Array(repeating: fill, count: max(0, count - choices.count))
                return (role.id, bounded)
            })
    }

    func remember(_ choices: [String: [HarnessChoice]], for type: CoreWorkflowType) {
        var saved = defaults.dictionary(forKey: Self.key) ?? [:]
        saved[type.preferenceKey] = choices.mapValues { $0.map(\.harness.rawValue) }
        defaults.set(saved, forKey: Self.key)
        var options = defaults.dictionary(forKey: Self.optionsKey) ?? [:]
        options[type.preferenceKey] = choices.mapValues { roleChoices in
            roleChoices.map { choice in
                var option: [String: String] = [:]
                option["model"] = choice.model
                option["effort"] = choice.effort
                if choice.yolo { option["yolo"] = "true" }
                return option
            }
        }
        defaults.set(options, forKey: Self.optionsKey)
    }
}
