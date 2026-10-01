import Foundation
import Testing

@testable import Twine

@MainActor
struct WorkflowLaunchPreferencesTests {
    @Test func explicitLaunchSuiteIsIsolatedFromOtherLaunches() throws {
        let first = "TwineLaunchTests-\(UUID())"
        let second = "TwineLaunchTests-\(UUID())"
        let firstStore = WorkflowLaunchPreferences.defaultStore(environment: ["TWINE_PREFERENCES_SUITE": first])
        let secondStore = WorkflowLaunchPreferences.defaultStore(environment: ["TWINE_PREFERENCES_SUITE": second])
        defer {
            firstStore.removePersistentDomain(forName: first)
            secondStore.removePersistentDomain(forName: second)
        }
        let choice = HarnessChoice(harness: .piAgent, model: "spark1/qwen38-27b")
        WorkflowLaunchPreferences(defaults: firstStore).remember(
            ["worker": [choice]], for: type(id: 1, version: 1, min: 1, max: 1))
        let reloaded = WorkflowLaunchPreferences.defaultStore(environment: ["TWINE_PREFERENCES_SUITE": first])
        #expect(
            WorkflowLaunchPreferences(defaults: reloaded).choices(for: type(id: 1, version: 1, min: 1, max: 1))[
                "worker"] == [choice])
        #expect(
            WorkflowLaunchPreferences(defaults: secondStore).choices(for: type(id: 1, version: 1, min: 1, max: 1))[
                "worker"] == [.init(harness: .codex)])
        #expect(WorkflowLaunchPreferences.defaultStore(environment: [:]) === UserDefaults.standard)
    }

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
                    .init(harness: .antigravity, model: "gemini-3.8-flash-high", effort: "high", yolo: true),
                    .init(harness: .omp, model: "local/model", effort: "max", yolo: true),
                ]
            ],
            for: first)
        let reloaded = WorkflowLaunchPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        let workers = reloaded.choices(for: type(id: 1, version: 2))["worker"]
        #expect(workers?.map(\.harness) == [.piAgent, .claudeCode, .codex, .antigravity, .omp])
        #expect(workers?.first == .init(harness: .piAgent, model: "local/m1", effort: "high", yolo: true))
        #expect(
            workers?[3] == .init(harness: .antigravity, model: "gemini-3.8-flash-high", effort: "high", yolo: true))
        #expect(workers?.last == .init(harness: .omp, model: "local/model", effort: "max", yolo: true))
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

    @Test func opencodeModelVariantsPersistAcrossRelaunch() throws {
        let suite = "TwineLaunchTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let choice = HarnessChoice(harness: .opencode, model: "opencode/space-bunny-free", effort: "high", yolo: false)
        WorkflowLaunchPreferences(defaults: defaults).remember(
            ["worker": [choice]], for: type(id: 1, version: 1, min: 1, max: 1))
        let reloaded = WorkflowLaunchPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(reloaded.choices(for: type(id: 1, version: 2, min: 1, max: 1))["worker"] == [choice])
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
