import CoreGraphics
import Foundation
import Testing

@testable import Twine

@MainActor
struct WorkflowGraphTests {
    @Test func builtInGraphsDecodeStagesHandoffsAndReviewBounds() async throws {
        let types = try await catalog()
        let adversarial = try #require(types.first { $0.reference.builtin == "adversarial" })
        #expect(adversarial.definition.stages.map(\.id) == ["implement", "review"])
        #expect(adversarial.definition.stages[1].completion.reviewer == "reviewer")
        #expect(adversarial.definition.handoffs.map(\.content) == [.result, .feedback])
        #expect(adversarial.definition.reviewLoops.first?.maxRounds == 3)
        let layout = WorkflowGraphLayout(definition: adversarial.definition, width: 180, compact: true)
        #expect(layout.edges.count == 2)
        #expect(layout.edges.last?.laneX != nil)
        #expect(layout.edges.last?.destination.stageID == "implement")
    }

    @Test func coordinatorFanOutAndFanInFollowTheChosenInstanceCount() async throws {
        let type = try #require(try await catalog().first { $0.reference.builtin == "coordinator" })
        for compact in [true, false] {
            for count in 2...5 {
                let layout = WorkflowGraphLayout(
                    definition: type.definition, counts: ["worker": count], width: 140, compact: compact)
                #expect(layout.rows.map { $0.nodes.count } == [1, count, 1])
                #expect(layout.edges.filter { $0.content == .assignment }.count == count)
                #expect(layout.edges.filter { $0.content == .result }.count == count)
                #expect(
                    layout.handoffDescriptions.contains("Coordinator in Split sends assignment to Worker 1 in Work."))
                #expect(layout.handoffDescriptions.contains("Worker 1 in Work sends result to Coordinator in Gather."))
                for row in layout.rows {
                    for node in row.nodes {
                        #expect(node.frame.minX >= 0 && node.frame.maxX <= layout.size.width)
                        #expect(node.frame.minY >= 0 && node.frame.maxY <= layout.size.height)
                    }
                    for pair in zip(row.nodes, row.nodes.dropFirst()) {
                        #expect(!pair.0.frame.intersects(pair.1.frame))
                    }
                }
            }
        }
    }

    @Test func graphUsesCustomStageIDsAndRolesWithoutNameBasedLayouts() async throws {
        var type = try #require(try await catalog().first { $0.reference.builtin == "adversarial" })
        type = .init(
            reference: .init(user: .init(typeID: 44, version: 2)),
            definition: .init(
                name: "Custom", description: "Two parallel roles", roles: type.definition.roles,
                stages: [
                    .init(
                        id: "custom-stage", name: "Review", roles: ["reviewer", "implementer"],
                        completion: .init(rule: .allRolesDone))
                ]))
        let layout = WorkflowGraphLayout(definition: type.definition, width: 0, compact: false)
        #expect(layout.rows.map(\.id) == ["custom-stage"])
        #expect(layout.rows[0].nodes.map { $0.role.id } == ["reviewer", "implementer"])
        #expect(layout.edges.isEmpty)
        #expect(layout.size.width.isFinite && layout.size.height > 0)
    }

    @Test func handoffDescriptionsUseCustomRoleAndStageNames() {
        let definition = BridgeWorkflowType.Definition(
            name: "Writing", description: "",
            roles: [
                .init(id: "author", name: "Writer", instances: .init(min: 1, max: 1)),
                .init(id: "analyst", name: "Analyst", instances: .init(min: 1, max: 1)),
            ],
            stages: [
                .init(id: "draft-x", name: "Draft words", roles: ["author"], completion: .init(rule: .allRolesDone)),
                .init(id: "edit-x", name: "Edit words", roles: ["analyst"], completion: .init(rule: .allRolesDone)),
            ],
            handoffs: [
                .init(
                    from: .init(stage: "draft-x", role: "author"),
                    destination: .init(stage: "edit-x", role: "analyst"), content: .result)
            ])
        let graph = WorkflowGraphLayout(definition: definition, width: 0, compact: false)
        #expect(graph.handoffDescriptions == ["Writer in Draft words sends result to Analyst in Edit words."])
    }

    private func catalog() async throws -> [BridgeWorkflowType] {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TwineGraphTests-\(UUID())")
        let worker = BridgeWorker(dataDirectory: directory)
        do {
            let snapshot = try await worker.open()
            let types = try #require(snapshot.workflowTypes)
            await worker.close()
            try FileManager.default.removeItem(at: directory)
            return types
        } catch {
            await worker.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
