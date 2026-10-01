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
        preferences.remember(
            [
                "worker": [
                    .init(harness: .piAgent, model: "local/m1", effort: "high", yolo: true),
                    .init(harness: .claudeCode),
                    .init(harness: .codex),
                ]
            ],
            for: first)
        let reloaded = WorkflowLaunchPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        let workers = reloaded.choices(for: type(id: 1, version: 2))["worker"]
        #expect(workers?.map(\.harness) == [.piAgent, .claudeCode, .codex])
        #expect(workers?.first == .init(harness: .piAgent, model: "local/m1", effort: "high", yolo: true))
        #expect(workers?.last?.model == nil)
        #expect(workers?.last?.yolo == false)
        #expect(
            reloaded.choices(for: type(id: 2, version: 1))["worker"] == [
                .init(harness: .codex), .init(harness: .codex),
            ])
    }

    @Test func updatedRoleBoundsTrimAndFillSavedChoices() throws {
        let suite = "TwineLaunchTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = WorkflowLaunchPreferences(defaults: defaults)
        preferences.remember(
            ["worker": [.init(harness: .piAgent), .init(harness: .claudeCode), .init(harness: .codex, model: "m")]],
            for: type(id: 1, version: 1))
        #expect(
            preferences.choices(for: type(id: 1, version: 2, min: 1, max: 1))["worker"]?.map(\.harness) == [.piAgent])
        // Extra instances start like the last saved one.
        #expect(
            preferences.choices(for: type(id: 1, version: 2, min: 4, max: 4))["worker"]
                == [
                    .init(harness: .piAgent), .init(harness: .claudeCode), .init(harness: .codex, model: "m"),
                    .init(harness: .codex, model: "m"),
                ])
    }

    @Test func harnessesSavedBeforeModelsExistedStillLoad() throws {
        let suite = "TwineLaunchTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["custom-1": ["worker": ["pi", "claudeCode"]]], forKey: "workflowRoleHarnesses")
        let choices = WorkflowLaunchPreferences(defaults: defaults).choices(for: type(id: 1, version: 3))
        #expect(choices["worker"] == [.init(harness: .piAgent), .init(harness: .claudeCode)])
    }

    private func type(id: UInt64, version: UInt32, min: Int = 2, max: Int = 5) -> CoreWorkflowType {
        .init(
            reference: .init(user: .init(typeID: id, version: version)),
            definition: .init(
                name: "Custom", description: "",
                roles: [
                    .init(id: "worker", name: "Worker", instances: .init(min: min, max: max))
                ]))
    }
}
