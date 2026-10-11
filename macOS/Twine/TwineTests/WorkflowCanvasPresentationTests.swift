import SwiftUI
import Testing

@testable import Twine

@Suite(.serialized)
@MainActor
struct WorkflowCanvasPresentationTests {
    @Test(arguments: [280.0, 550.0])
    func graphPreviewReportsItsRenderedHeightIncludingFeedback(width: Double) throws {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let implementer = model.addGraphRole(at: .init(x: 380, y: 220))
        let reviewer = model.addGraphRole(at: .init(x: 700, y: 220))
        model.connect(from: implementer, to: reviewer)
        model.connect(from: reviewer, to: implementer, event: .feedback)
        let type = CoreWorkflowType(reference: .init(builtin: "adversarial"), definition: model.definition)
        let preview = WorkflowGraph(type: type)
        let renderer = ImageRenderer(content: preview.frame(width: width))
        let image = try #require(renderer.cgImage)
        // The popover must reserve the height of the displayed graph, not the empty stage layout.
        #expect(preview.height == CGFloat(image.height))
    }

    @Test(arguments: ["Writer", "Reviewer", "Coordinator"])
    func graphCardsStayCompactInALargeLayoutProposal(title: String) throws {
        let renderer = ImageRenderer(
            content: WorkflowGraphCard(title: title))
        renderer.proposedSize = .init(width: 1200, height: 740)
        let image = try #require(renderer.cgImage)
        // A large canvas proposal must not turn endpoint cards into full-height columns.
        #expect(image.width < 240)
        #expect(image.height < 130)
    }

    @Test(arguments: [-600.0, 220.0, 1600.0, 4000.0])
    func draggedConnectionsKeepTheirVisibleEndsOutsideTheDrawingHeight(agentY: Double) throws {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let agent = model.addGraphRole()
        let receiver = model.addGraphRole()
        model.connect(from: agent, to: receiver)
        model.definition.roles[0].color = .red
        let renderer = ImageRenderer(
            content: WorkflowGraphConnections(
                model: model, selection: .constant(nil), source: nil, pointer: nil, target: nil,
                point: { id in
                    CGPoint(x: id == receiver ? 900 : 480, y: id == agent ? agentY : 220)
                }
            )
            .frame(width: 960, height: 440))
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        // The moved end can leave the drawing area. The other end must still be visible.
        let visibleEnd = (780..<800).contains { horizontal in
            (210..<230).contains { vertical in
                guard let color = bitmap.colorAt(x: horizontal, y: vertical)?.usingColorSpace(.deviceRGB) else {
                    return false
                }
                return color.alphaComponent > 0.3 && color.redComponent > color.greenComponent + 0.1
                    && color.redComponent > color.blueComponent + 0.1
            }
        }
        #expect(visibleEnd)
    }

    @Test func oppositeDirectionLinksHaveSeparateEventButtons() throws {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let implementer = model.addGraphRole()
        let reviewer = model.addGraphRole()
        model.connect(from: implementer, to: reviewer)
        model.connect(from: reviewer, to: implementer, event: .feedback)
        let links = try #require(
            model.definition.graph?.edges.filter {
                $0.from == implementer && $0.to == reviewer || $0.from == reviewer && $0.to == implementer
            })
        let view = WorkflowGraphConnections(
            model: model, selection: .constant(nil), source: nil, pointer: nil, target: nil,
            point: { id in CGPoint(x: id == implementer ? 400 : 700, y: 280) })
        model.definition.roles[0].name = "Implementer"
        model.definition.roles[1].name = "Reviewer"
        #expect(view.linkTitle(links[0]) == "Implementer to Reviewer: Work complete")
        model.definition.roles[1].name = "Auditor"
        #expect(view.linkTitle(links[1]) == "Auditor to Implementer: Changes requested")
        let first = view.labelPoint(links[0])
        let second = view.labelPoint(links[1])
        #expect(first.x == second.x)
        #expect(abs(first.y - second.y) >= 30)
    }

    @Test func addingAfterDeletionUsesAFreeRowAndPreservesExistingPositions() throws {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let removed = model.addGraphRole()
        let retained = model.addGraphRole()
        let previous = try #require(model.definition.graph?.positions[retained])
        model.removeGraphRole(removed)
        let added = model.addGraphRole()
        let position = try #require(model.definition.graph?.positions[added])
        #expect(model.definition.graph?.positions[retained] == previous)
        #expect(abs(position.x - previous.x) >= 216 || abs(position.y - previous.y) >= 112)
    }

    @Test func connectionsRejectInvalidEndpointsAndDuplicateEvents() {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let first = model.addGraphRole()
        let second = model.addGraphRole()
        #expect(model.canConnect(from: first, to: second))
        model.connect(from: first, to: second)
        let count = model.definition.graph?.edges.count
        model.connect(from: first, to: second)
        #expect(model.definition.graph?.edges.count == count)
        #expect(!model.canConnect(from: first, to: second))
        #expect(model.canConnect(from: first, to: second, event: .feedback))
        #expect(!model.canConnect(from: first, to: first))
        #expect(!model.canConnect(from: first, to: "task"))
        #expect(!model.canConnect(from: "finish", to: second))
        #expect(!model.canConnect(from: "task", to: "finish"))
        let roleTaskAllowed = model.canConnect(from: first, to: second, event: CoreWorkflowType.GraphEvent.task)
        #expect(roleTaskAllowed == false)
        #expect(!model.canConnect(from: "task", to: second, event: .done))
        #expect(!model.canConnect(from: first, to: "finish", event: .pieceReady))
        #expect(!model.canConnect(from: first, to: "finish", event: .feedback))
        #expect(!model.canConnect(from: first, to: "finish", event: .approved))
        model.removeGraphRole(second)
        #expect(!model.canConnect(from: first, to: second))
        #expect(!model.canConnect(from: second, to: "finish"))
    }

    @Test func fitIncludesCardsAtBothSavedCoordinateLimits() {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let first = model.addGraphRole()
        let second = model.addGraphRole()
        model.definition.graph?.positions[first] = .init(x: 0, y: 0)
        model.definition.graph?.positions[second] = .init(x: 4000, y: 4000)
        model.connect(from: second, to: first)
        model.connect(from: second, to: first, event: .pieceReady)
        let viewport = CGSize(width: 640, height: 320)
        let scale = WorkflowEditorLayout.fitScale(for: model.definition, viewport: viewport)
        let size = WorkflowEditorLayout.canvasSize(for: model.definition)
        let offset = WorkflowEditorLayout.originOffset(for: model.definition)
        let halfCard = CGSize(
            width: WorkflowEditorLayout.cardSize.width / 2, height: WorkflowEditorLayout.cardSize.height / 2)
        #expect(offset.width - halfCard.width >= WorkflowEditorLayout.canvasMargin)
        #expect(offset.height - halfCard.height >= WorkflowEditorLayout.canvasMargin)
        #expect((4000 + offset.width + halfCard.width) * scale <= viewport.width)
        #expect((4000 + offset.height + halfCard.height) * scale <= viewport.height)
        #expect(scale < 0.25)
        #expect(size.width * scale <= viewport.width)
        #expect(size.height * scale <= viewport.height)
        #expect(size.height > 4000 + offset.height + halfCard.height + 56 + 30)
    }

    @Test func returnEventsUseSeparateLanesInsideTheCanvas() throws {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let first = model.addGraphRole(at: .init(x: 200, y: 400))
        let second = model.addGraphRole(at: .init(x: 600, y: 400))
        model.connect(from: second, to: first)
        model.connect(from: second, to: first, event: .pieceReady)
        let edges = try #require(model.definition.graph?.edges)
        let view = WorkflowGraphConnections(
            model: model, selection: .constant(nil), source: nil,
            pointer: nil, target: nil, point: { id in CGPoint(x: id == first ? 200 : 600, y: 400) })
        #expect(abs(view.labelPoint(edges[0]).y - view.labelPoint(edges[1]).y) == 30)
    }

    @Test func overviewDescribesUnlinkedAgentsAndCurrentNames() {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let first = model.addGraphRole()
        model.definition.roles[0].name = "Writer"
        let single = WorkflowGraphOverview(definition: model.definition).accessibilitySummary
        #expect(single.contains("Writer") && single.contains("Starts here") && single.contains("Returns result"))
        let second = model.addGraphRole()
        model.definition.roles[1].name = "Checker"
        model.connect(from: first, to: second)
        #expect(WorkflowGraphOverview(definition: model.definition).accessibilitySummary.contains("Writer to Checker"))
    }

    @Test func duplicateKeepsAgentSettingsWithoutCopyingLinks() throws {
        let model = WorkflowDesignerModel()
        model.enableGraph()
        let first = model.addGraphRole()
        let second = model.addGraphRole()
        model.definition.roles[0].instructions = "Review the work."
        model.definition.roles[0].agentDefaults = .init(choice: .init(harness: .claudeCode))
        model.definition.graph?.receive[first] = .all
        model.setGraphReview(first, enabled: true)
        model.connect(from: first, to: second)
        let copy = try #require(model.duplicateGraphAgent(first))
        let original = model.definition.roles[0]
        let duplicate = try #require(model.definition.roles.first { $0.id == copy })
        #expect(duplicate.instructions == original.instructions)
        #expect(duplicate.color == original.color && duplicate.agentDefaults == original.agentDefaults)
        #expect(duplicate.instances.min == 1 && duplicate.instances.max == 1)
        #expect(model.definition.graph?.receive[copy] == .all)
        #expect(model.definition.graph?.reviewsWork(copy) == true)
        #expect(model.definition.graph?.edges.contains { $0.from == copy || $0.to == copy } == false)
    }

}
