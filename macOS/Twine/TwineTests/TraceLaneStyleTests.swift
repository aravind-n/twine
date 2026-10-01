import SwiftUI
import Testing

@testable import Twine

@MainActor
struct TraceLaneStyleTests {
    private func lane(_ id: UInt64, role: String? = nil, harness: String? = nil) -> CoreTraceLane {
        .init(
            laneID: id, workflowID: 1, name: role ?? "Terminal", isAgent: role != nil, role: role, harness: harness)
    }

    @Test func shellAndCodexUseDifferentColorsAndRepeatedRolesRemainDistinct() throws {
        let tracks = [
            lane(1, role: "agent", harness: "codex"), lane(2), lane(3, role: "Worker"), lane(4, role: "Worker 2"),
        ]
        let colors = TraceLaneStyle.colors(for: tracks)
        #expect(colors[1] == .roleBlue)
        #expect(colors[2] == .roleGreen)
        for first in tracks {
            for second in tracks where first.id != second.id {
                #expect(colors[first.id] != colors[second.id])
            }
            #expect(TraceLaneStyle.color(for: first, colors: colors) == colors[first.id])
        }
    }

    @Test func trackColorsSurviveReorderingRenamingAndLoadingAnOlderTrack() {
        let original = [lane(10, role: "Implementer"), lane(20, role: "Implementer")]
        let colors = TraceLaneStyle.colors(for: original)
        let updated = TraceLaneStyle.colors(
            for: [lane(20, role: "Renamed"), lane(5), original[0]], retaining: colors)
        #expect(updated[10] == colors[10])
        #expect(updated[20] == colors[20])
        #expect(updated[5] != updated[10])
        #expect(updated[5] != updated[20])
        let cleared = TraceLaneStyle.colors(for: [], retaining: updated)
        let alone = TraceLaneStyle.colors(for: [original[1]], retaining: cleared)
        let returned = TraceLaneStyle.colors(for: original, retaining: alone)
        #expect(returned[10] == colors[10])
        #expect(returned[20] == colors[20])
    }

    @Test func separatelyViewedTracksGetDistinctColorsWhenCombined() {
        let first = lane(1, role: "Implementer")
        let second = lane(2, role: "Implementer")
        let original = TraceLaneStyle.colors(for: [first])
        let separately = TraceLaneStyle.colors(for: [second], retaining: original)
        #expect(separately[first.id] == separately[second.id])
        let together = TraceLaneStyle.colors(for: [second, first], retaining: separately)
        #expect(together[first.id] == original[first.id])
        #expect(together[first.id] != together[second.id])
        #expect(TraceLaneStyle.colors(for: [second, first], retaining: together) == together)
    }
}
