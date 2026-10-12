import Foundation
import SwiftUI
import Testing

@testable import Twine

@Suite(.serialized)
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
            model.definition.graph?.maxActivations = 0
            await model.validate(using: client)
            #expect(model.issues.contains { $0.element == "graph" })
            model.definition.graph?.maxActivations = 4
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
            model.enableGraph()
            await model.validate(using: client)
            #expect(!model.issues.contains { $0.element == "name" })
            #expect(model.issues.contains { $0.element == "roles" })
            model.definition.name = "Write a draft"
            model.addGraphRole()
            model.definition.roles[0].name = "Author"
            model.definition.roles[0].instructions = "Write the requested draft."
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
        #expect(model.definition.roles[0].name == "New agent")
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
    @Test func graphCopiesKeepSplitAndGatherSeparateAndValidate() async throws {
        let directory = TemporaryPath()
        let client = CoreClient(transport: CoreWorker(dataDirectory: directory.url))
        client.start()
        do {
            try await client.waitUntilRunning()
            for type in try #require(client.snapshot?.workflowTypes?.filter { $0.reference.builtin != nil }) {
                let model = WorkflowDesignerModel(type: type)
                model.enableGraph()
                await model.validate(using: client)
                #expect(model.issues.isEmpty)
                #expect(model.definition.roles.reduce(0) { $0 + $1.instances.max } <= 5)
                if type.reference.builtin == "coordinator" {
                    let split = try #require(model.definition.roles.first { $0.id == "planner" })
                    let gather = try #require(model.definition.roles.first { $0.id == "coordinator" })
                    let edges = try #require(model.definition.graph?.edges)
                    for worker in ["worker-1", "worker-2"] {
                        #expect(edges.contains { $0.from == split.id && $0.to == worker })
                        #expect(edges.contains { $0.from == worker && $0.to == gather.id })
                        #expect(!edges.contains { $0.from == gather.id && $0.to == worker })
                    }
                    #expect(model.definition.graph?.receive[gather.id] == .all)
                    #expect(model.conversionNotice == nil)
                    #expect(model.definition.roles.allSatisfy { $0.instances.min == 1 && $0.instances.max == 1 })
                }
            }
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    @Test func graphLinksKeepDistinctEventsAndRejectExactDuplicates() throws {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let source = model.addGraphRole()
        let destination = model.addGraphRole()
        model.connect(from: source, to: destination)
        model.connect(from: source, to: destination, event: .pieceReady)
        model.connect(from: source, to: destination, event: .pieceReady)
        let edges = try #require(model.definition.graph?.edges.filter { $0.from == source && $0.to == destination })
        #expect(Set(edges.map(\.event)) == [.done, .pieceReady])
        #expect(edges.count == 2)
    }

    @Test func graphUndoAndRedoRestoreRoleLinksPositionsAndReceiveRules() {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let manager = UndoManager()
        manager.groupsByEvent = false
        let before = model.definition
        manager.beginUndoGrouping()
        let id = model.addGraphRole()
        model.definition.graph?.receive[id] = .all
        model.recordUndo(from: before, using: manager)
        manager.endUndoGrouping()
        let added = model.definition
        manager.undo()
        #expect(model.definition == before)
        model.recordUndo(from: added, using: manager)
        manager.redo()
        #expect(model.definition == added)
        model.recordUndo(from: before, using: manager)
        manager.beginUndoGrouping()
        model.removeGraphRole(id)
        model.recordUndo(from: added, using: manager)
        manager.endUndoGrouping()
        let removed = model.definition
        manager.undo()
        #expect(model.definition == added)
        model.recordUndo(from: removed, using: manager)
        manager.redo()
        #expect(model.definition == removed)
    }

}
