import SwiftUI
import Testing

@testable import Twine

struct PaneDividerZoomTests {
    @Test func draggingAClampedNestedDividerStartsFromItsDisplayedPosition() throws {
        let id = UUID()
        let split = TerminalSplit.branch(
            id, .down, 0.9, .pane(1), .branch(UUID(), .down, 0.5, .pane(2), .pane(3)))
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 512)
        let divider = try #require(split.geometry(in: bounds).dividers.first { $0.id == id })
        let usable = bounds.height - BentoLayout.gutter
        #expect(abs(divider.fraction * usable + BentoLayout.gutter / 2 - divider.frame.midY) < 0.001)
        let moved = PaneDivider.fraction(start: divider.fraction, translation: -60, sharedLength: usable, scale: 1)
        let next = try #require(split.resizing(id, fraction: moved).geometry(in: bounds).dividers.first { $0.id == id })
        #expect(abs(next.frame.midY - divider.frame.midY + 60) < 0.001)
    }

    @Test func nestedDownSplitsReserveRowsEvenWithUnevenFractions() {
        let nested = TerminalSplit.branch(
            UUID(), .down, 0.5, .pane(1),
            .branch(UUID(), .down, 0.5, .pane(2), .branch(UUID(), .down, 0.5, .pane(3), .pane(4))))
        for paneHeight in [100.0, 160.0] {
            let size = CGSize(width: 800, height: nested.minimumHeight(paneHeight: paneHeight))
            let panes = nested.geometry(in: CGRect(origin: .zero, size: size), paneHeight: paneHeight).panes
            #expect(panes.count == 4)
            for frame in panes.values { #expect(frame.height >= paneHeight - 0.001) }
        }
    }

    @Test(arguments: [0.5, 1, 2])
    func dividerTracksWindowTranslationAtEveryZoom(scale: Double) {
        let start = 0.5
        let logicalLength = 400.0
        for translation in [-100.0, 100.0] {
            let fraction = PaneDivider.fraction(
                start: start, translation: translation, sharedLength: logicalLength, scale: scale)
            let windowMovement = (fraction - start) * logicalLength * scale
            #expect(abs(windowMovement - translation) < 0.001)
        }
        #expect(PaneDivider.fraction(start: start, translation: 100, sharedLength: 0, scale: scale) == start)
    }
}
