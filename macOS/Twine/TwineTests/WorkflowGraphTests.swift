import CoreGraphics
import Foundation
import Testing

@testable import Twine

@MainActor
struct WorkflowGraphTests {
    @Test func builtInGraphsDecodeAgentLinksAndReviewBounds() async throws {
        let types = try await catalog()
        let adversarial = try #require(types.first { $0.reference.builtin == "adversarial" })
        #expect(adversarial.definition.stages.isEmpty)
        let graph = try #require(adversarial.definition.graph)
        #expect(graph.edges.count == 2)
        #expect(graph.startsAgent("implementer"))
        #expect(graph.returnsResult("reviewer") && graph.reviewsWork("reviewer"))
        #expect(graph.maxActivations == 4)
    }

    @Test func coordinatorHasSeparateWorkerCardsAndWaitsForBothResults() async throws {
        let type = try #require(try await catalog().first { $0.reference.builtin == "coordinator" })
        let graph = try #require(type.definition.graph)
        #expect(type.definition.roles.map(\.id) == ["planner", "worker-1", "worker-2", "coordinator"])
        #expect(type.definition.roles.allSatisfy { $0.instances.min == 1 && $0.instances.max == 1 })
        #expect(graph.receive["coordinator"] == .all)
        for worker in ["worker-1", "worker-2"] {
            #expect(graph.edges.contains { $0.from == "planner" && $0.to == worker })
            #expect(graph.edges.contains { $0.from == worker && $0.to == "coordinator" })
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
        let layout = WorkflowGraphLayout(definition: type.definition, width: 0)
        #expect(layout.columns.map(\.id) == ["custom-stage"])
        #expect(layout.columns[0].nodes.map { $0.role.id } == ["reviewer", "implementer"])
        #expect(layout.edges.isEmpty)
        #expect(layout.connectors.isEmpty)
        #expect(layout.size.width.isFinite && layout.size.height > 0)
    }

    @Test func handoffDescriptionsUseCustomRoleAndStageNames() {
        let definition = CoreWorkflowType.Definition(
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
        let graph = WorkflowGraphLayout(definition: definition, width: 0)
        #expect(graph.handoffDescriptions == ["Writer in Draft words sends result to Analyst in Edit words."])
    }

    @Test func separateHandoffsAcrossOneGapGetTheirOwnTrunks() {
        let definition = definition(
            roles: ["x", "y", "p", "q"],
            stages: [("a", ["x", "y"]), ("b", ["p", "q"])],
            handoffs: [handoff("a.x", "b.q", .result), handoff("a.y", "b.p", .result)])
        let layout = WorkflowGraphLayout(definition: definition, width: 600)
        let trunks = layout.connectors.map { $0.lines[0][1].x }
        #expect(Set(trunks).count == 2)
        // Both handoffs carry results, so they share one label.
        #expect(layout.labels.count == 1)
    }

    @Test func feedbackLanesGoAroundNodesAndReachEveryInstance() {
        let definition = definition(
            roles: ["implementer", "reviewer", "tester"],
            stages: [("implement", ["implementer"]), ("review", ["reviewer", "tester"])],
            handoffs: [
                handoff("implement.implementer", "review.reviewer", .result),
                handoff("review.reviewer", "implement.implementer", .feedback),
            ],
            maxInstances: ["implementer": 3])
        let layout = WorkflowGraphLayout(definition: definition, counts: ["implementer": 3], width: 600)
        let feedback = layout.connectors[1]
        #expect(feedback.lines.count == 3)
        let nodes = layout.columns.flatMap(\.nodes)
        for (line, target) in zip(feedback.lines, layout.columns[0].nodes) {
            for (start, end) in zip(line, line.dropFirst()) {
                let segment = CGRect(
                    x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
                    height: abs(end.y - start.y))
                for node in nodes where node.id != target.id && node.id != "review-reviewer-1" {
                    #expect(!segment.intersects(node.frame.insetBy(dx: 1, dy: 1)), "\(node.id)")
                }
            }
        }
    }

    @Test func stageStatesFollowTheRunStatus() throws {
        let definition = definition(
            roles: ["a", "b", "c"], stages: [("one", ["a"]), ("two", ["b"]), ("three", ["c"])], handoffs: [])
        func states(_ status: String) throws -> [WorkflowStageState] {
            let json =
                #"{"generation":1,"stage":"Two","status":"\#(status)","needsTask":false,"agents":[],"stageId":"two"}"#
            let run = try JSONDecoder().decode(CoreWorkflowRun.self, from: Data(json.utf8))
            return definition.stages.map { WorkflowStageState.of($0.id, in: definition, run: run) }
        }
        #expect(try states("running") == [.done, .current, .pending])
        #expect(try states("completed") == [.done, .done, .done])
        for status in ["limitReached", "cancelled", "failed", "interrupted"] {
            #expect(try states(status) == [.done, .idle, .idle])
        }
        #expect(
            definition.stages.map { WorkflowStageState.of($0.id, in: definition, run: nil) } == [.idle, .idle, .idle])
    }

    @Test func legacyParallelInstancesMakeTheGraphTaller() {
        let definition = definition(
            roles: ["worker"], stages: [("work", ["worker"])], handoffs: [], maxInstances: ["worker": 5])
        let two = WorkflowGraphLayout(definition: definition, counts: ["worker": 2], width: 568)
        let five = WorkflowGraphLayout(definition: definition, counts: ["worker": 5], width: 568)
        #expect(five.size.height > two.size.height)
    }

    private func definition(
        roles: [String], stages: [(String, [String])],
        handoffs: [CoreWorkflowType.Handoff],
        maxInstances: [String: Int] = [:]
    ) -> CoreWorkflowType.Definition {
        CoreWorkflowType.Definition(
            name: "Test", description: "",
            roles: roles.map {
                .init(id: $0, name: $0.capitalized, instances: .init(min: 1, max: maxInstances[$0] ?? 1))
            },
            stages: stages.map {
                .init(id: $0.0, name: $0.0.capitalized, roles: $0.1, completion: .init(rule: .allRolesDone))
            },
            handoffs: handoffs)
    }

    /// A handoff between two "stage.role" endpoints.
    private func handoff(
        _ from: String, _ destination: String, _ content: CoreWorkflowType.HandoffContent
    ) -> CoreWorkflowType.Handoff {
        func endpoint(_ value: String) -> CoreWorkflowType.Endpoint {
            let parts = value.split(separator: ".").map(String.init)
            return .init(stage: parts[0], role: parts[1])
        }
        return .init(from: endpoint(from), destination: endpoint(destination), content: content)
    }

    private func catalog() async throws -> [CoreWorkflowType] {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TwineGraphTests-\(UUID())")
        let worker = CoreWorker(dataDirectory: directory)
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
