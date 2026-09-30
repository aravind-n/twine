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
        let layout = WorkflowGraphLayout(definition: adversarial.definition, width: 180)
        #expect(layout.edges.count == 2)
        #expect(layout.labels.map(\.text) == ["Result", "Feedback · up to 3 rounds"])
        #expect(
            layout.handoffDescriptions.last
                == "Reviewer in Review sends feedback to Implementer in Implement. Up to 3 rounds.")
        // Feedback runs back under the columns and ends at the implementer's bottom edge.
        let implementer = try #require(layout.columns.first?.nodes.first)
        let feedback = try #require(layout.connectors.last?.lines.first)
        #expect(feedback.dropFirst().dropLast().allSatisfy { $0.y > implementer.frame.maxY })
        #expect(feedback.last?.x == implementer.frame.midX)
        #expect(layout.labels.last?.center.y ?? 0 < layout.size.height)
    }

    @Test func coordinatorFanOutAndFanInFollowTheChosenInstanceCount() async throws {
        let type = try #require(try await catalog().first { $0.reference.builtin == "coordinator" })
        for count in 2...5 {
            let layout = WorkflowGraphLayout(definition: type.definition, counts: ["worker": count], width: 568)
            #expect(layout.columns.map { $0.nodes.count } == [1, count, 1])
            #expect(layout.edges.filter { $0.content == .assignment }.count == count)
            #expect(layout.edges.filter { $0.content == .result }.count == count)
            #expect(layout.handoffDescriptions.contains("Coordinator in Split sends assignment to Worker 1 in Work."))
            #expect(layout.handoffDescriptions.contains("Worker 1 in Work sends result to Coordinator in Gather."))
            // Each fan turns at one shared trunk; a worker level with the coordinator gets a straight line.
            for connector in layout.connectors {
                #expect(connector.lines.count == count)
                #expect(Set(connector.lines.filter { $0.count > 2 }.map { $0[1].x }).count == 1)
            }
            #expect(layout.labels.count == 2)
            for column in layout.columns {
                for node in column.nodes {
                    // The running ring reaches just past a node's edges.
                    #expect(CGRect(origin: .zero, size: layout.size).contains(node.frame.insetBy(dx: -1, dy: -1)))
                }
                for pair in zip(column.nodes, column.nodes.dropFirst()) {
                    #expect(!pair.0.frame.intersects(pair.1.frame))
                }
            }
            for pair in zip(layout.columns, layout.columns.dropFirst()) {
                #expect(pair.0.nodes[0].frame.maxX < pair.1.nodes[0].frame.minX)
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

    @Test func moreParallelInstancesMakeTheGraphTaller() async throws {
        let type = try #require(try await catalog().first { $0.reference.builtin == "coordinator" })
        let two = WorkflowGraphLayout(definition: type.definition, width: 568)
        let five = WorkflowGraphLayout(definition: type.definition, counts: ["worker": 5], width: 568)
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
