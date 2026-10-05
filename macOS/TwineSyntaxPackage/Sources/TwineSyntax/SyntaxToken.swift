import Foundation

public enum SyntaxTokenKind: String, CaseIterable, Sendable {
    case keyword, string, comment, number, type, function, property, `operator`, punctuation, variable

    init?(capture: [String]) {
        guard let first = capture.first else { return nil }
        switch first {
        case "keyword", "boolean", "constant": self = .keyword
        case "string" where capture.contains("key"): self = .property
        case "string", "character", "escape": self = .string
        case "comment": self = .comment
        case "number", "float": self = .number
        case "type", "constructor", "tag", "module": self = .type
        case "function": self = .function
        case "property", "attribute": self = .property
        case "operator": self = .operator
        case "punctuation", "delimiter": self = .punctuation
        case "variable" where capture.contains("member"): self = .property
        case "variable", "label": self = .variable
        default: return nil
        }
    }
}

/// A half-open range of UTF16 code units, directly usable by NSTextView.
public struct SyntaxToken: Equatable, Sendable {
    public let range: NSRange
    public let kind: SyntaxTokenKind

    public init(range: NSRange, kind: SyntaxTokenKind) {
        self.range = range
        self.kind = kind
    }
}

struct SyntaxCapture {
    let token: SyntaxToken
    let specificity: Int
    let patternIndex: Int

    /// Narrow captures override enclosing nodes, then qualified names override generic names.
    /// Query order breaks ties, matching Tree-sitter's specialized-pattern convention.
    func outranks(_ other: SyntaxCapture) -> Bool {
        if token.range.length != other.token.range.length {
            return token.range.length < other.token.range.length
        }
        if specificity != other.specificity { return specificity > other.specificity }
        return patternIndex > other.patternIndex
    }
}

/// Sweep capture boundaries with a priority heap, yielding sorted, disjoint presentation runs.
/// This keeps nested interpolation and generic/specialized query captures deterministic.
struct SyntaxTokenNormalizer {
    private var heap: [SyntaxCapture] = []

    mutating func normalize(
        _ captures: [SyntaxCapture], deadline: ContinuousClock.Instant
    ) throws -> [SyntaxToken] {
        let clock = ContinuousClock()
        var comparisons = 0
        func checkBudget() throws {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw SyntaxParserError.timedOut }
        }
        let ordered = try captures.sorted {
            comparisons += 1
            if comparisons.isMultiple(of: 1024) { try checkBudget() }
            return $0.token.range.location < $1.token.range.location
        }
        try checkBudget()
        let boundaries = try Set(ordered.flatMap { [$0.token.range.location, NSMaxRange($0.token.range)] }).sorted {
            comparisons += 1
            if comparisons.isMultiple(of: 1024) { try checkBudget() }
            return $0 < $1
        }
        var nextCapture = 0
        var result: [SyntaxToken] = []
        for (index, start) in boundaries.dropLast().enumerated() {
            if index.isMultiple(of: 256) { try checkBudget() }
            let end = boundaries[index + 1]
            while nextCapture < ordered.count, ordered[nextCapture].token.range.location == start {
                insert(ordered[nextCapture])
                nextCapture += 1
            }
            while let first = heap.first, NSMaxRange(first.token.range) <= start { removeFirst() }
            guard let active = heap.first else { continue }
            let range = NSRange(location: start, length: end - start)
            if let last = result.last, last.kind == active.token.kind, NSMaxRange(last.range) == start {
                result[result.count - 1] = SyntaxToken(
                    range: NSRange(location: last.range.location, length: end - last.range.location), kind: last.kind
                )
            } else {
                result.append(SyntaxToken(range: range, kind: active.token.kind))
            }
        }
        try checkBudget()
        return result
    }

    private mutating func insert(_ capture: SyntaxCapture) {
        heap.append(capture)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].outranks(heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func removeFirst() {
        let last = heap.removeLast()
        guard !heap.isEmpty else { return }
        heap[0] = last
        var parent = 0
        while parent * 2 + 1 < heap.count {
            var child = parent * 2 + 1
            if child + 1 < heap.count, heap[child + 1].outranks(heap[child]) { child += 1 }
            guard heap[child].outranks(heap[parent]) else { break }
            heap.swapAt(parent, child)
            parent = child
        }
    }
}
