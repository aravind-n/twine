import CoreGraphics
import Foundation
import Testing

@testable import Twine

struct TerminalSplitTests {
    @Test func nestedSplitsPersistAndCollapseWithoutLosingTheirNeighbor() throws {
        let tree = TerminalSplit.pane(1).inserting(3, beside: 1, direction: .right)
            .inserting(4, beside: 3, direction: .down)
        let decoded = try JSONDecoder().decode(TerminalSplit.self, from: JSONEncoder().encode(tree))
        #expect(decoded == tree)
        #expect(decoded.ids == [1, 3, 4])
        let geometry = decoded.geometry(in: CGRect(x: 0, y: 0, width: 1000, height: 600))
        #expect(geometry.panes[1]?.height == 600)
        #expect(geometry.panes[3]?.width == geometry.panes[4]?.width)
        let top = try #require(geometry.panes[3])
        let bottom = try #require(geometry.panes[4])
        #expect(top.maxY < bottom.minY)
        let remaining = try #require(decoded.retaining([3, 4]))
        #expect(remaining.ids == [3, 4])
        #expect(remaining.geometry(in: CGRect(x: 0, y: 0, width: 1000, height: 600)).panes[3]?.width == 1000)
        #expect(remaining.retaining([4]) == .pane(4))
    }

    @Test func undersizedPanelsNeverProduceNegativePaneSizes() {
        let tree = TerminalSplit.pane(1).inserting(2, beside: 1, direction: .right)
            .inserting(3, beside: 2, direction: .down)
        for width in [0.0, 4, 100, 1000] {
            let layout = tree.geometry(in: CGRect(x: 0, y: 0, width: width, height: 4))
            #expect(layout.panes.values.allSatisfy { $0.width >= 0 && $0.height >= 0 })
        }
    }
}
