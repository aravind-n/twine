import SwiftUI

extension WorkflowDesignerModel {
    // Controls can briefly retain their binding after a row is removed. Resolve by identity on
    // every access, keeping the removed value readable without writing into a neighboring row.
    func roleBinding(_ role: CoreWorkflowType.Role) -> Binding<CoreWorkflowType.Role> {
        elementBinding(role, path: \.definition.roles) { self.definition.roles.firstIndex { $0.id == role.id } }
    }

    func stageBinding(_ stage: CoreWorkflowType.Stage) -> Binding<CoreWorkflowType.Stage> {
        elementBinding(stage, path: \.definition.stages) { self.definition.stages.firstIndex { $0.id == stage.id } }
    }

    func handoffBinding(_ handoff: CoreWorkflowType.Handoff, id: UUID) -> Binding<CoreWorkflowType.Handoff> {
        elementBinding(handoff, path: \.definition.handoffs) { self.handoffIDs.firstIndex(of: id) }
    }

    func loopBinding(_ loop: CoreWorkflowType.ReviewLoop, id: UUID) -> Binding<CoreWorkflowType.ReviewLoop> {
        elementBinding(loop, path: \.definition.reviewLoops) { self.loopIDs.firstIndex(of: id) }
    }

    private func elementBinding<Element>(
        _ fallback: Element, path: ReferenceWritableKeyPath<WorkflowDesignerModel, [Element]>,
        index: @escaping () -> Int?
    ) -> Binding<Element> {
        Binding(
            get: {
                guard let index = index(), self[keyPath: path].indices.contains(index) else { return fallback }
                return self[keyPath: path][index]
            },
            set: { value in
                guard let index = index(), self[keyPath: path].indices.contains(index) else { return }
                self[keyPath: path][index] = value
            })
    }
}
