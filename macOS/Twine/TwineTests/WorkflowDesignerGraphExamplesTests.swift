import Foundation
import SwiftUI
import Testing

@testable import Twine

@Suite(.serialized)
@MainActor
struct WorkflowDesignerGraphExamplesTests {
    @Test func deletingASavedGraphRemovesItFromChoicesAndAllowsItsNameToBeUsedAgain() async throws {
        let directory = TemporaryPath()
        let client = CoreClient(transport: CoreWorker(dataDirectory: directory.url))
        client.start()
        do {
            try await client.waitUntilRunning()
            let model = try makeAdversarial()
            model.definition.name = "Delete test workflow"
            await model.validate(using: client)
            let saved = try #require(await model.save(using: client))
            let result = try await client.sendAndAwaitCompletion(
                .deleteWorkflowType(reference: saved.reference, expectedDefinition: saved.definition))
            #expect(result == .workflowTypeDeleted(reference: saved.reference))
            #expect(client.snapshot?.workflowTypes?.contains(saved) == false)
            await client.stop()
            client.start()
            try await client.waitUntilRunning()
            #expect(client.snapshot?.workflowTypes?.contains(saved) == false)
            let replacement = try #require(await model.save(using: client))
            #expect(replacement.reference != saved.reference)
            #expect(replacement.definition.name == saved.definition.name)
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    @Test func emptyNamesReturnTheSavedTitleAndDuplicateNamesShowTheCoreError() async throws {
        let directory = TemporaryPath()
        let client = CoreClient(transport: CoreWorker(dataDirectory: directory.url))
        client.start()
        do {
            try await client.waitUntilRunning()
            let first = try makeAdversarial()
            first.definition.name = ""
            await first.validate(using: client)
            #expect(first.canSave)
            let saved = try #require(await first.save(using: client))
            #expect(!saved.definition.name.isEmpty)
            #expect(client.snapshot?.workflowTypes?.contains(saved) == true)

            let duplicate = try makeAdversarial()
            duplicate.definition.name = saved.definition.name.uppercased()
            await duplicate.validate(using: client)
            #expect(await duplicate.save(using: client) == nil)
            #expect(duplicate.failure == "A workflow with this name already exists.")
            #expect(client.snapshot?.workflowTypes?.contains(saved) == true)
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    @Test func builtInPatternsCanBeCreatedFromBlankSavedEditedAndReopened() async throws {
        let directory = TemporaryPath()
        let client = CoreClient(transport: CoreWorker(dataDirectory: directory.url))
        client.start()
        do {
            try await client.waitUntilRunning()
            let adversarial = try makeAdversarial()
            let coordinator = try makeCoordinator()
            var saved: [CoreWorkflowType] = []
            for model in [adversarial, coordinator, makeExpandedGroup()] {
                await model.validate(using: client)
                #expect(model.issues.isEmpty)
                let first = try #require(await model.save(using: client))
                #expect(first.definition == model.definition)
                let reopened = try #require(client.snapshot?.workflowTypes?.first { $0.reference == first.reference })
                #expect(reopened.definition == first.definition)
                let editor = WorkflowDesignerModel(type: first)
                editor.enableGraph()
                #expect(editor.definition == first.definition)
                editor.definition.description += " Edited and saved again."
                await editor.validate(using: client)
                let result = await editor.save(using: client)
                #expect(editor.failure == nil)
                #expect(editor.issues.isEmpty)
                let revised = try #require(result)
                #expect(revised.reference.user?.typeID == first.reference.user?.typeID)
                #expect(revised.reference.user?.version == 2)
                #expect(revised.definition.graph == first.definition.graph)
                #expect(revised.definition.roles == first.definition.roles)
                saved.append(revised)
            }
            await client.stop()
            client.start()
            try await client.waitUntilRunning()
            for type in saved {
                #expect(client.snapshot?.workflowTypes?.contains(type) == true)
            }
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    private func makeAdversarial() throws -> WorkflowDesignerModel {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        model.definition.name = "Editor test: Adversarial"
        let implementer = model.addGraphRole()
        let reviewer = model.addGraphRole()
        model.roleBinding(model.definition.roles[0]).wrappedValue.name = "Implementer"
        model.roleBinding(model.definition.roles[1]).wrappedValue.name = "Reviewer"
        model.definition.roles[0].color = .blue
        model.definition.roles[1].color = .orange
        model.definition.roles[0].agentDefaults = .init(choice: .init(harness: .codex))
        model.definition.roles[1].agentDefaults = .init(choice: .init(harness: .claudeCode))
        model.connect(from: implementer, to: reviewer)
        model.connect(from: reviewer, to: implementer, event: .feedback)
        model.definition.graph?.maxActivations = 4
        #expect(model.definition.graph?.edges.count == 2)
        #expect(model.definition.graph?.reviewsWork(reviewer) == true)
        #expect(model.definition.graph?.returnsResult(reviewer) == true)
        #expect(model.definition.stages.isEmpty)
        return model
    }

    private func makeCoordinator() throws -> WorkflowDesignerModel {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        model.definition.name = "Editor test: Coordinator (shared plan)"
        let planner = model.addGraphRole()
        let worker = model.addGraphRole()
        let workerTwo = try #require(model.duplicateGraphAgent(worker))
        let coordinator = model.addGraphRole()
        let binding = model.roleBinding(model.definition.roles[0])
        binding.wrappedValue.name = "Planner"
        binding.wrappedValue.instructions =
            "Send a plan with separate tasks for Worker 1 and Worker 2."
        model.definition.roles[1].name = "Worker 1"
        model.definition.roles[2].name = "Worker 2"
        model.definition.roles[3].name = "Coordinator"
        model.definition.graph?.receive[coordinator] = .all
        for id in [worker, workerTwo] {
            model.connect(from: planner, to: id)
            model.connect(from: id, to: coordinator)
        }
        #expect(model.definition.roles.count == 4)
        #expect(model.definition.graph?.edges.count == 4)
        #expect(model.definition.graph?.startsAgent(planner) == true)
        #expect(model.definition.graph?.returnsResult(coordinator) == true)
        return model
    }

    private func makeExpandedGroup() -> WorkflowDesignerModel {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        model.definition.name = "Editor test: Older worker group"
        model.addGraphRole()
        model.addGraphRole()
        model.definition.roles[0].id = "worker"
        model.definition.roles[0].name = "Worker"
        model.definition.roles[0].instances = .init(min: 2, max: 2)
        model.definition.roles[0].agentDefaults = .init(choice: .init(harness: .claudeCode))
        model.definition.roles[1].id = "worker-2"
        model.definition.graph?.positions = [:]
        model.connect(from: "worker", to: "worker-2")
        model.enableGraph()
        let ids = model.definition.roles.map(\.id)
        #expect(Set(ids).count == 3)
        #expect(ids.contains("worker-2-2"))
        #expect(model.definition.graph?.edges.count == 2)
        #expect(model.definition.roles[2].id == "worker-2")
        #expect(model.definition.roles[1].agentDefaults == model.definition.roles[0].agentDefaults)
        return model
    }
}
