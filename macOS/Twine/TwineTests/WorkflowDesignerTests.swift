import Foundation
import SwiftUI
import Testing

@testable import Twine

@MainActor
struct WorkflowDesignerTests {
    @Test func designerValidatesElementsCopiesBuiltinsAndPublishesSavedVersions() async throws {
        let directory = TemporaryPath()
        let client = CoreClient(transport: CoreWorker(dataDirectory: directory.url))
        client.start()
        do {
            try await client.waitUntilRunning()
            let builtin = try #require(client.snapshot?.workflowTypes?.first)
            let model = WorkflowDesignerModel(type: builtin)
            #expect(model.definition.name == "\(builtin.definition.name) copy")
            #expect(!model.canSave)
            await model.validate(using: client)
            #expect(model.canSave)
            let instructions = model.definition.roles[0].instructions
            #expect(!instructions.isEmpty)
            model.definition.roles[0].instructions = ""
            #expect(!model.canSave)
            await model.validate(using: client)
            #expect(model.issues.contains { $0.element == "roles[0]" })
            #expect(await model.save(using: client) == nil)
            model.definition.roles[0].instructions = instructions
            model.definition.reviewLoops[0].maxRounds = 0
            await model.validate(using: client)
            #expect(model.issues.contains { $0.element == "review_loops[0]" })
            model.definition.reviewLoops[0].maxRounds = 4
            await model.validate(using: client)
            let saved = try #require(await model.save(using: client))
            #expect(saved.reference.builtin == nil)
            #expect(saved.reference.user?.version == 1)
            #expect(client.snapshot?.workflowTypes?.contains(saved) == true)
            #expect(client.snapshot?.workflowTypes?.contains(builtin) == true)
            let editor = WorkflowDesignerModel(type: saved)
            editor.definition.name = "Revised copy"
            await editor.validate(using: client)
            let revised = try #require(await editor.save(using: client))
            #expect(revised.reference.user?.typeID == saved.reference.user?.typeID)
            #expect(revised.reference.user?.version == 2)
            #expect(client.snapshot?.workflowTypes?.contains(saved) == false)
            #expect(client.snapshot?.workflowTypes?.contains(revised) == true)
            await client.stop()
            // Reopening the same store must load the edited type, including role instructions.
            client.start()
            try await client.waitUntilRunning()
            #expect(client.snapshot?.workflowTypes?.contains(revised) == true)
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    @Test func blankDesignCanBeBuiltAndSavedThroughTheRealCore() async throws {
        let directory = TemporaryPath()
        let client = CoreClient(transport: CoreWorker(dataDirectory: directory.url))
        client.start()
        do {
            try await client.waitUntilRunning()
            let model = WorkflowDesignerModel()
            await model.validate(using: client)
            #expect(Set(model.issues.map(\.element)) == ["name", "roles", "stages"])
            model.definition.name = "Write a draft"
            model.addRole()
            model.definition.roles[0].name = "Author"
            model.definition.roles[0].instructions = "Write the requested draft."
            model.addStage()
            model.definition.stages[0].roles = [model.definition.roles[0].id]
            await model.validate(using: client)
            #expect(model.canSave)
            let saved = try #require(await model.save(using: client))
            #expect(saved.definition == model.definition)
            #expect(client.snapshot?.workflowTypes?.contains(saved) == true)
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    @Test func removingElementsKeepsReferencesRepairable() {
        let model = WorkflowDesignerModel()
        model.addRole()
        model.addRole()
        model.addStage()
        model.addStage()
        model.definition.stages[0].roles = [model.definition.roles[0].id]
        model.definition.stages[1].roles = [model.definition.roles[1].id]
        model.addHandoff()
        model.addLoop()
        model.removeRole(at: 0)
        #expect(model.definition.stages[0].roles.isEmpty)
        #expect(model.definition.handoffs.isEmpty)
        model.removeStage(at: 1)
        #expect(model.definition.reviewLoops.isEmpty)
    }

    @Test func retainedBindingsFollowIdentityAcrossMovesAndIgnoreRemovedRows() throws {
        let model = WorkflowDesignerModel()
        model.addRole()
        model.addRole()
        let removedRole = model.definition.roles[1]
        let roleBinding = model.roleBinding(removedRole)
        model.removeRole(at: 1)
        #expect(roleBinding.wrappedValue == removedRole)
        roleBinding.wrappedValue.name = "Discarded edit"
        #expect(model.definition.roles[0].name == "New role")
        model.addStage()
        model.addStage()
        let stage = model.definition.stages[0]
        let stageBinding = model.stageBinding(stage)
        model.definition.stages.swapAt(0, 1)
        stageBinding.wrappedValue.name = "Moved stage"
        #expect(model.definition.stages[1].name == "Moved stage")
        #expect(model.definition.stages[0].name == "New stage")
        model.addHandoff()
        let handoff = model.definition.handoffs[0]
        let handoffBinding = model.handoffBinding(handoff, id: try #require(model.handoffIDs.first))
        model.removeHandoff(at: 0)
        handoffBinding.wrappedValue.content = .feedback
        #expect(handoffBinding.wrappedValue == handoff)
        #expect(model.definition.handoffs.isEmpty)
        model.addLoop()
        let loop = model.definition.reviewLoops[0]
        let loopBinding = model.loopBinding(loop, id: try #require(model.loopIDs.first))
        model.removeLoop(at: 0)
        loopBinding.wrappedValue.maxRounds = 10
        #expect(loopBinding.wrappedValue == loop)
        #expect(model.definition.reviewLoops.isEmpty)
    }
}
