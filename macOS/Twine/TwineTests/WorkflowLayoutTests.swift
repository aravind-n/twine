import CoreGraphics
import Foundation
import Testing

@testable import Twine

@MainActor
struct WorkflowLayoutTests {
    private static let agents = ["Implementer", "Reviewer", "Coordinator", "Worker", "Tester"].enumerated().map {
        CoreAgent(agentID: UInt64($0.offset + 1), role: $0.element, terminalID: UInt64($0.offset + 11))
    }

    @Test func panesKeepTheSavedOrderThenFillInRoleOrder() {
        let three = Array(Self.agents.prefix(3))
        var layout = WorkflowLayout(paneAgentIDs: [3, 99, 3, 1])
        #expect(layout.panes(of: three).map(\.id) == [3, 1, 2], "Unknown and repeated agents are dropped")
        #expect(layout.panes(of: Self.agents).map(\.id) == [3, 1, 2, 4], "At most four panes")
        #expect(layout.focusedAgent(in: three)?.id == 1, "Without a focused agent, the first has the keyboard")
        layout.focusedAgentID = 5
        #expect(layout.focusedAgent(in: Self.agents)?.id == 5)
        #expect(layout.panes(of: Self.agents).map(\.id) == [3, 1, 2, 5], "The focused agent always has a pane")
        #expect(layout.focusedAgent(in: three)?.id == 1, "A missing agent's focus falls back to the first")
        #expect(layout.focusedAgent(in: []) == nil)
        #expect(layout.panes(of: []).isEmpty)
    }

    @Test func focusingAnAgentWithoutAPaneReplacesTheFocusedPane() {
        var layout = WorkflowLayout(mode: .bento, focusedAgentID: 2)
        layout.focus(5, in: Self.agents)
        #expect(layout.focusedAgentID == 5)
        #expect(layout.panes(of: Self.agents).map(\.id) == [1, 5, 3, 4])
        layout.focus(3, in: Self.agents)
        #expect(layout.panes(of: Self.agents).map(\.id) == [1, 5, 3, 4], "An agent with a pane keeps it")
        layout.focus(99, in: Self.agents)
        #expect(layout.focusedAgentID == 3, "Unknown agents can't take the keyboard")

        var tabs = WorkflowLayout(focusedAgentID: 2)
        tabs.focus(5, in: Self.agents)
        #expect(tabs.focusedAgentID == 5)
        #expect(tabs.paneAgentIDs.isEmpty, "Tab mode leaves the panes alone")
    }

    @Test func placingAnAgentSwapsItWithItsPaneAndFocusesIt() {
        let three = Array(Self.agents.prefix(3))
        var layout = WorkflowLayout(mode: .bento, focusedAgentID: 1)
        layout.place(3, inPane: 0, of: three)
        #expect(layout.panes(of: three).map(\.id) == [3, 2, 1])
        #expect(layout.focusedAgentID == 3)
        layout.place(5, inPane: 1, of: Self.agents)
        #expect(layout.panes(of: Self.agents).map(\.id) == [3, 5, 1, 4], "An agent without a pane takes it")
        let placed = layout
        layout.place(99, inPane: 0, of: Self.agents)
        layout.place(2, inPane: 4, of: Self.agents)
        #expect(layout == placed, "Unknown agents and panes change nothing")
    }

    @Test func theKeyboardMovesThroughPanesInBentoModeAndAgentsInTabMode() {
        let three = Array(Self.agents.prefix(3))
        var layout = WorkflowLayout(mode: .bento, focusedAgentID: 3, paneAgentIDs: [3, 1, 2])
        layout.moveFocus(by: 1, in: three)
        #expect(layout.focusedAgentID == 1)
        layout.moveFocus(by: -1, in: three)
        layout.moveFocus(by: -1, in: three)
        #expect(layout.focusedAgentID == 2, "Moving back from the first pane wraps to the last")
        layout.moveFocus(by: 1, in: three)
        #expect(layout.focusedAgentID == 3, "Moving on from the last pane wraps to the first")

        var tabs = WorkflowLayout(focusedAgentID: 4)
        tabs.moveFocus(by: 1, in: Self.agents)
        #expect(tabs.focusedAgentID == 5, "Tab mode reaches agents that Bento mode has no pane for")
        tabs.moveFocus(by: 1, in: Self.agents)
        #expect(tabs.focusedAgentID == 1)
        #expect(tabs.paneAgentIDs.isEmpty, "Tab mode leaves the panes alone")
    }

    @Test func movingTheKeyboardKeepsThePanesOnScreen() {
        // A focused fifth agent takes the last pane, as after relaunch with it focused and no panes saved.
        var layout = WorkflowLayout(mode: .bento, focusedAgentID: 5)
        #expect(layout.panes(of: Self.agents).map(\.id) == [1, 2, 3, 5])
        layout.focus(1, in: Self.agents)
        #expect(layout.panes(of: Self.agents).map(\.id) == [1, 2, 3, 5], "Agent 5 keeps its pane")
        layout.moveFocus(by: -1, in: Self.agents)
        #expect(layout.focusedAgentID == 5, "Moving back from the first pane reaches agent 5")

        var moved = WorkflowLayout(mode: .bento, focusedAgentID: 5)
        moved.moveFocus(by: 1, in: Self.agents)
        #expect(moved.focusedAgentID == 1)
        #expect(moved.panes(of: Self.agents).map(\.id) == [1, 2, 3, 5])
    }

    @Test func panesArrangeInColumnsAndGiveWayInSmallPanels() {
        let large = CGSize(width: 1_200, height: 800)
        func columns(_ panes: [UInt64], focused: UInt64, size: CGSize = large) -> [[UInt64]] {
            PaneArrangement(panes: panes, focusedAgentID: focused, size: size).columns.map(\.agentIDs)
        }
        #expect(columns([1, 2], focused: 1) == [[1], [2]])
        #expect(columns([1, 2, 3], focused: 1) == [[1], [2, 3]])
        #expect(columns([1, 2, 3, 4], focused: 1) == [[1, 2], [3, 4]])

        // Two minimum panes and three gutters fit exactly; a point less doesn't.
        let minimum = BentoLayout.minimumPaneSize
        let narrow = CGSize(width: 2 * minimum.width + 3 * BentoLayout.gutter - 1, height: large.height)
        let short = CGSize(width: large.width, height: 2 * minimum.height + 3 * BentoLayout.gutter - 1)
        #expect(columns([1, 2, 3, 4], focused: 1, size: CGSize(width: narrow.width + 1, height: 800)).count == 2)
        #expect(columns([1, 2, 3, 4], focused: 4, size: narrow) == [[3, 4]], "The focused pane's column stays")
        #expect(columns([1, 2, 3], focused: 3, size: short) == [[1], [3]], "Each column keeps one pane")
        #expect(columns([1, 2, 3, 4], focused: 2, size: short) == [[2], [3]])
        let tiny = PaneArrangement(panes: [1, 2, 3, 4], focusedAgentID: 4, size: CGSize(width: 300, height: 100))
        #expect(tiny.visibleAgentIDs == [4])
        #expect(!tiny.isTiled, "One pane fills the panel, as in tab mode")
        #expect(PaneArrangement(focusedAgentID: 2).visibleAgentIDs == [2])
        #expect(PaneArrangement(focusedAgentID: nil).visibleAgentIDs.isEmpty)
    }

    @Test func paneFramesTileThePanelWithGuttersAndKeepPanesAtTheirMinimum() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1_006, height: 606)
        let gutter = BentoLayout.gutter
        let arrangement = PaneArrangement(panes: [1, 2, 3, 4], focusedAgentID: 1, size: bounds.size)
        let frames = arrangement.frames(in: bounds, columnFraction: 0.5, rowFractions: [0.25, 0.5])
        // 1,006 − 3 gutters leaves 988 points to share, and 606 − 3 gutters leaves 588.
        expect(frames[.agent(1)], CGRect(x: gutter, y: gutter, width: 494, height: 150), "Clamped to 150")
        expect(frames[.agent(2)], CGRect(x: gutter, y: 2 * gutter + 150, width: 494, height: 438))
        expect(frames[.agent(3)], CGRect(x: 2 * gutter + 494, y: gutter, width: 494, height: 294))
        expect(frames[.agent(4)], CGRect(x: 2 * gutter + 494, y: 2 * gutter + 294, width: 494, height: 294))
        let divider = try #require(frames[.columnDivider])
        #expect(abs(divider.midX - (gutter + 494 + gutter / 2)) < 0.001, "The divider is centered in the gutter")
        #expect(abs((frames[.rowDivider(1)]?.midY ?? 0) - (gutter + 294 + gutter / 2)) < 0.001)

        let squeezed = arrangement.frames(in: bounds, columnFraction: 0.01, rowFractions: [])
        let minimumWidth = BentoLayout.minimumPaneSize.width
        expect(squeezed[.agent(1)], CGRect(x: gutter, y: gutter, width: minimumWidth, height: 294), "Even rows")

        // SwiftUI can lay the panes out smaller than their gutters before their measured size catches up.
        for tiny in [CGRect.zero, CGRect(x: 0, y: 0, width: 8, height: 3)] {
            let placed = arrangement.frames(in: tiny, columnFraction: 0.5, rowFractions: [0.5, 0.5])
            #expect(placed.count == 7, "Four panes, a column divider, and two row dividers")
            for frame in placed.values {
                let isFinite = [frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite }
                #expect(isFinite && frame.width >= 0 && frame.height >= 0, "\(frame)")
            }
        }

        let single = PaneArrangement(focusedAgentID: 3)
        #expect(single.frames(in: bounds, columnFraction: 0.5, rowFractions: []) == [.agent(3): bounds])
    }

    @Test func splitFractionsStayUsable() {
        #expect(PaneArrangement.clampedFraction(0.9, panelLength: 618, minimum: 150) == 0.75)
        #expect(PaneArrangement.clampedFraction(-1, panelLength: 618, minimum: 150) == 0.25)
        #expect(PaneArrangement.clampedFraction(.nan, panelLength: 618, minimum: 150) == 0.5)
        #expect(PaneArrangement.clampedFraction(0.9, panelLength: 100, minimum: 150) == 0.5, "Too small to split")
        #expect(PaneArrangement.clampedFraction(0.3, panelLength: 0, minimum: 150) == 0.5)
    }

    @Test func layoutsAreSavedBesideTheDatabaseAndPrunedWhenWorkflowsClose() async throws {
        let directory = TemporaryPath()
        let file = directory.url.appending(path: "workflow-layouts.json")
        let layouts = WorkflowLayouts(fileURL: file)
        await layouts.load()
        let bento = WorkflowLayout(mode: .bento, focusedAgentID: 3, paneAgentIDs: [3, 1], columnFraction: 0.3)
        layouts.setLayout(bento, for: 7, in: "/first")
        layouts.setLayout(WorkflowLayout(focusedAgentID: 2), for: 8, in: "/first")
        layouts.setLayout(bento, for: 9, in: "/second")
        await layouts.flush()

        let relaunched = WorkflowLayouts(fileURL: file)
        await relaunched.load()
        #expect(relaunched.layout(for: 7, in: "/first") == bento)
        #expect(relaunched.layout(for: 9, in: "/second") == bento)
        #expect(relaunched.layout(for: 9, in: "/first") == WorkflowLayout(), "Layouts belong to their folder")

        // Only the folder's own loaded list prunes: not another folder's, a missing one, or one still loading.
        relaunched.removeClosedWorkflows(in: "/first", state: workflowState(folder: "/second", workflowIDs: [9]))
        relaunched.removeClosedWorkflows(in: "/first", state: workflowState(folder: "/first", isLoaded: false))
        relaunched.removeClosedWorkflows(in: "/first", state: nil)
        #expect(relaunched.layout(for: 7, in: "/first") == bento)
        relaunched.removeClosedWorkflows(in: "/first", state: workflowState(folder: "/first", workflowIDs: [8]))
        await relaunched.flush()
        let pruned = WorkflowLayouts(fileURL: file)
        await pruned.load()
        #expect(pruned.layout(for: 7, in: "/first") == WorkflowLayout())
        #expect(pruned.layout(for: 8, in: "/first").focusedAgentID == 2)
        #expect(pruned.layout(for: 9, in: "/second") == bento, "Other folders' layouts stay")
    }

    @Test func unreadableLayoutsStartInTabMode() async throws {
        let directory = TemporaryPath()
        try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
        let file = directory.url.appending(path: "workflow-layouts.json")
        let missing = WorkflowLayouts(fileURL: file)
        await missing.load()
        #expect(missing.layout(for: 1, in: "/f") == WorkflowLayout())

        try Data("{not json".utf8).write(to: file)
        let corrupt = WorkflowLayouts(fileURL: file)
        await corrupt.load()
        #expect(corrupt.layout(for: 1, in: "/f") == WorkflowLayout())
        corrupt.setLayout(WorkflowLayout(mode: .bento), for: 1, in: "/f")
        await corrupt.flush()
        let replaced = WorkflowLayouts(fileURL: file)
        await replaced.load()
        #expect(replaced.layout(for: 1, in: "/f").mode == .bento, "The next change replaces an unreadable file")
    }
}

/// A folder's workflow state as the core publishes it, with one session.
private func workflowState(folder: String, workflowIDs: [UInt64] = [], isLoaded: Bool = true) -> CoreWorkflowState {
    CoreWorkflowState(
        sessionsInitialized: isLoaded,
        session: CoreSession(
            sessionID: 1, name: "Session", folder: folder, status: .active, startedAt: 0, endedAt: nil),
        workflows: workflowIDs.map {
            CoreWorkflow(
                workflowID: $0, sessionID: 1, name: "Agents", kind: .agents, terminalID: 0, status: .running,
                startedAt: 0, endedAt: nil)
        })
}

private func expect(
    _ frame: CGRect?, _ expected: CGRect, _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation
) {
    let matches = frame.map { frame in
        [
            frame.minX - expected.minX, frame.minY - expected.minY, frame.width - expected.width,
            frame.height - expected.height,
        ].allSatisfy { abs($0) < 0.001 }
    }
    #expect(
        matches == true, "\(String(describing: frame)) isn't \(expected). \(comment?.rawValue ?? "")",
        sourceLocation: sourceLocation)
}
