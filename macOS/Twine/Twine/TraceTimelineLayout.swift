import Foundation

/// Geometry only. Overlap packing uses displayed pill widths, including the minimum hit area.
nonisolated struct TraceTimelineLayout {
    struct Placement: Identifiable, Equatable {
        let span: CoreTraceSpan
        let offset: CGFloat
        let width: CGFloat
        let row: Int
        var id: UInt64 { span.id }
    }

    let origin: UInt64
    let duration: Double

    init(spans: [CoreTraceSpan], now: UInt64) {
        origin = spans.map(\.startedAt).min() ?? now
        let end = spans.map { $0.end(at: now) }.max() ?? origin
        duration = max(1_000, Double(end - origin))
    }

    func placements(spans: [CoreTraceSpan], width: CGFloat, now: UInt64) -> [Placement] {
        let width = max(40, width)
        var rowEnds: [CGFloat] = []
        return spans.sorted {
            $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt
        }.map { span in
            let pillWidth = min(width, max(40, CGFloat(Double(span.end(at: now) - span.startedAt) / duration) * width))
            let offset = min(width - pillWidth, max(0, CGFloat(Double(span.startedAt - origin) / duration) * width))
            let row = rowEnds.firstIndex { $0 + 4 <= offset } ?? rowEnds.count
            if row == rowEnds.count { rowEnds.append(0) }
            rowEnds[row] = offset + pillWidth
            return Placement(span: span, offset: offset, width: pillWidth, row: row)
        }
    }

    func tickLabel(_ index: Int) -> String {
        TraceFormatting.elapsed(UInt64(duration * Double(index) / 4))
    }
}
