import Foundation
import Observation

nonisolated struct CoreWorkflowValidationIssue: Decodable, Equatable, Sendable {
    let element: String
    let message: String
}

@Observable
final class WorkflowDesignerModel {
    var definition: CoreWorkflowType.Definition
    private(set) var handoffIDs: [UUID] = []
    private(set) var loopIDs: [UUID] = []
    let source: CoreWorkflowType.Reference?
    private(set) var issues: [CoreWorkflowValidationIssue] = []
    private(set) var validatedDefinition: CoreWorkflowType.Definition?
    private(set) var isSaving = false
    private(set) var failure: String?

    init(type: CoreWorkflowType? = nil) {
        source = type?.reference
        definition = type?.definition ?? .init(name: "", description: "", roles: [])
        handoffIDs = definition.handoffs.map { _ in UUID() }
        loopIDs = definition.reviewLoops.map { _ in UUID() }
        if type?.reference.builtin != nil { definition.name += " copy" }
    }

    var canSave: Bool { validatedDefinition == definition && issues.isEmpty && !isSaving }
    var isValidating: Bool { validatedDefinition != definition }

    func validate(using client: CoreClient) async {
        let candidate = definition
        do {
            try Task.checkCancellation()
            let result = try await client.sendAndAwaitCompletion(.validateWorkflowType(definition: candidate))
            try Task.checkCancellation()
            guard definition == candidate else { return }
            guard case .workflowTypeValidated(let issues) = result else {
                throw CoreFailure.unexpectedCommandResult
            }
            self.issues = issues
            validatedDefinition = candidate
            failure = nil
        } catch is CancellationError {
            return
        } catch {
            guard definition == candidate else { return }
            failure = error.localizedDescription
            validatedDefinition = nil
        }
    }

    func save(using client: CoreClient) async -> CoreWorkflowType? {
        guard canSave else { return nil }
        isSaving = true
        defer { isSaving = false }
        let candidate = definition
        do {
            let result = try await client.sendAndAwaitCompletion(
                .saveWorkflowType(source: source, definition: candidate))
            switch result {
            case .workflowTypeSaved(let reference):
                return .init(reference: reference, definition: candidate)
            case .workflowTypeValidated(let issues):
                self.issues = issues
                validatedDefinition = candidate
            default: throw CoreFailure.unexpectedCommandResult
            }
        } catch { failure = error.localizedDescription }
        return nil
    }

    func addRole() {
        definition.roles.append(
            .init(
                id: UUID().uuidString, name: "New role", instances: .init(min: 1, max: 1)))
    }

    func removeRole(at index: Int) {
        let role = definition.roles.remove(at: index).id
        for stage in definition.stages.indices { definition.stages[stage].roles.removeAll { $0 == role } }
        for index in definition.handoffs.indices.reversed()
        where definition.handoffs[index].from.role == role || definition.handoffs[index].destination.role == role {
            removeHandoff(at: index)
        }
    }

    func addStage() {
        definition.stages.append(
            .init(
                id: UUID().uuidString, name: "New stage", roles: [], completion: .init(rule: .allRolesDone)))
    }

    func removeStage(at index: Int) {
        let stage = definition.stages.remove(at: index).id
        for index in definition.handoffs.indices.reversed()
        where definition.handoffs[index].from.stage == stage || definition.handoffs[index].destination.stage == stage {
            removeHandoff(at: index)
        }
        for index in definition.reviewLoops.indices.reversed()
        where definition.reviewLoops[index].reviewStage == stage || definition.reviewLoops[index].backTo == stage {
            removeLoop(at: index)
        }
    }

    func removeHandoff(at index: Int) {
        definition.handoffs.remove(at: index)
        handoffIDs.remove(at: index)
    }

    func removeLoop(at index: Int) {
        definition.reviewLoops.remove(at: index)
        loopIDs.remove(at: index)
    }

    func addHandoff() {
        handoffIDs.append(UUID())
        let from = definition.stages.first
        let destination = definition.stages.dropFirst().first
        definition.handoffs.append(
            .init(
                from: .init(stage: from?.id ?? "", role: from?.roles.first ?? ""),
                destination: .init(stage: destination?.id ?? "", role: destination?.roles.first ?? ""), content: .result
            ))
    }

    func addLoop() {
        loopIDs.append(UUID())
        definition.reviewLoops.append(
            .init(
                reviewStage: definition.stages.last?.id ?? "", backTo: definition.stages.first?.id ?? "", maxRounds: 3))
    }
}
