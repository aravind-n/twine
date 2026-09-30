import Foundation

/// Presentation-only form prefills. The core owns the assignments after a successful launch.
struct WorkflowLaunchPreferences {
    private let defaults: UserDefaults
    private static let key = "workflowRoleHarnesses"

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

    func harnesses(for type: BridgeWorkflowType) -> [String: [BridgeHarness]] {
        let saved = defaults.dictionary(forKey: Self.key)?[type.preferenceKey] as? [String: [String]] ?? [:]
        return Dictionary(
            uniqueKeysWithValues: type.definition.roles.map { role in
                let choices = (saved[role.id] ?? []).compactMap(BridgeHarness.init(rawValue:))
                let count = min(role.instances.max, max(role.instances.min, choices.count))
                let bounded =
                    Array(choices.prefix(count)) + Array(repeating: .codex, count: max(0, count - choices.count))
                return (role.id, bounded)
            })
    }

    func remember(_ harnesses: [String: [BridgeHarness]], for type: BridgeWorkflowType) {
        var saved = defaults.dictionary(forKey: Self.key) ?? [:]
        saved[type.preferenceKey] = harnesses.mapValues { $0.map(\.rawValue) }
        defaults.set(saved, forKey: Self.key)
    }
}
