import Foundation
import Testing

@testable import Twine

@MainActor
struct WorkflowLaunchPreferencesTests {
    @Test func lastHarnessesPersistByTypeAndAcrossNewCustomVersions() throws {
        let suite = "TwineLaunchTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = WorkflowLaunchPreferences(defaults: defaults)
        let first = type(id: 1, version: 1)
        preferences.remember(["worker": [.piAgent, .claudeCode, .codex]], for: first)
        let reloaded = WorkflowLaunchPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(reloaded.harnesses(for: type(id: 1, version: 2))["worker"] == [.piAgent, .claudeCode, .codex])
        #expect(reloaded.harnesses(for: type(id: 2, version: 1))["worker"] == [.codex, .codex])
    }

    @Test func updatedRoleBoundsTrimAndFillSavedChoices() throws {
        let suite = "TwineLaunchTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = WorkflowLaunchPreferences(defaults: defaults)
        preferences.remember(["worker": [.piAgent, .claudeCode, .codex]], for: type(id: 1, version: 1))
        #expect(preferences.harnesses(for: type(id: 1, version: 2, min: 1, max: 1))["worker"] == [.piAgent])
        #expect(
            preferences.harnesses(for: type(id: 1, version: 2, min: 4, max: 4))["worker"]
                == [.piAgent, .claudeCode, .codex, .codex])
    }

    private func type(id: UInt64, version: UInt32, min: Int = 2, max: Int = 5) -> BridgeWorkflowType {
        .init(
            reference: .init(user: .init(typeID: id, version: version)),
            definition: .init(
                name: "Custom", description: "",
                roles: [
                    .init(id: "worker", name: "Worker", instances: .init(min: min, max: max))
                ]))
    }
}
