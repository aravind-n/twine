import Foundation
import SwiftTreeSitter

public enum SyntaxParserError: Error, Equatable, Sendable {
    case tooLarge
    case timedOut
    case missingQuery(String)
}

/// Own one parser per editor document. Native parser/tree state never leaves this actor.
public actor SyntaxParser {
    /// Accommodate every document accepted by Twine's 2 MiB UTF8 file limit.
    public static let maximumUTF16Length = 2_097_152
    private static let maximumCaptures = 100_000
    private let parser = Parser()
    private var tree: MutableTree?
    private var previousUnits: [UInt16] = []
    private var currentLanguage: SyntaxLanguage?
    private var queries: [SyntaxLanguage: Query] = [:]

    public init() {}

    /// Returns sorted, non-overlapping ranges. A timeout or cancellation discards parser state.
    /// Parsing has a native deadline; query work also has a deadline and capture-count limit.
    public func highlight(_ source: String, language: SyntaxLanguage) throws -> [SyntaxToken] {
        try Task.checkCancellation()
        guard source.utf16.count <= Self.maximumUTF16Length else { throw SyntaxParserError.tooLarge }
        do {
            let query = try prepare(language)
            let units = Array(source.utf16)
            if let tree, let edit = Self.edit(from: previousUnits, to: units) { tree.edit(edit) }
            let bytes = units.withUnsafeBytes { Data($0) }
            parser.timeout = 0.35
            let parsed = parser.parse(tree: tree) { offset, _ in
                guard !Task.isCancelled, offset < bytes.count else { return nil }
                var end = min(bytes.count, offset + 4096)
                // A read chunk must not end halfway through a UTF16 surrogate pair.
                if end < bytes.count, (0xD800...0xDBFF).contains(units[end / 2 - 1]) { end += 2 }
                return bytes.subdata(in: offset..<end)
            }
            try Task.checkCancellation()
            guard let parsed else { throw SyntaxParserError.timedOut }
            tree = parsed
            previousUnits = units
            return try tokens(query: query, tree: parsed, source: source)
        } catch {
            parser.reset()
            tree = nil
            previousUnits = []
            throw error
        }
    }

    private func prepare(_ language: SyntaxLanguage) throws -> Query {
        if currentLanguage != language {
            parser.reset()
            tree = nil
            previousUnits = []
            try parser.setLanguage(language.grammar)
            currentLanguage = language
        }
        if let query = queries[language] { return query }
        var data = Data()
        for name in language.queryNames {
            guard let url = Bundle.module.url(forResource: name, withExtension: "scm", subdirectory: "Queries") else {
                throw SyntaxParserError.missingQuery(name)
            }
            data.append(try Data(contentsOf: url))
            data.append(10)
        }
        let query = try Query(language: language.grammar, data: data)
        queries[language] = query
        return query
    }

    private func tokens(query: Query, tree: MutableTree, source: String) throws -> [SyntaxToken] {
        let text = source as NSString
        let context = Predicate.Context { range, _ in
            guard range.location >= 0, NSMaxRange(range) <= text.length else { return nil }
            return text.substring(with: range)
        }
        let cursor = query.execute(in: tree)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(350))
        var captures: [SyntaxCapture] = []
        for match in cursor {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw SyntaxParserError.timedOut }
            guard match.allowed(in: context) else { continue }
            for capture in match.captures {
                guard let kind = SyntaxTokenKind(capture: capture.nameComponents),
                    capture.range.length > 0, capture.range.location >= 0, NSMaxRange(capture.range) <= text.length
                else { continue }
                captures.append(
                    SyntaxCapture(
                        token: SyntaxToken(range: capture.range, kind: kind),
                        specificity: capture.nameComponents.count, patternIndex: capture.patternIndex
                    )
                )
                guard captures.count <= Self.maximumCaptures else { throw SyntaxParserError.timedOut }
            }
        }
        try Task.checkCancellation()
        guard clock.now < deadline else { throw SyntaxParserError.timedOut }
        var normalizer = SyntaxTokenNormalizer()
        return try normalizer.normalize(captures, deadline: deadline)
    }

    /// Find a single contiguous replacement. Tree-sitter needs byte columns even for UTF16 input.
    private static func edit(from old: [UInt16], to new: [UInt16]) -> InputEdit? {
        var start = 0
        while start < min(old.count, new.count), old[start] == new[start] { start += 1 }
        if start == old.count, start == new.count { return nil }
        // Expand a differing low surrogate to include the preceding high surrogate.
        if start > 0, start < old.count, (0xDC00...0xDFFF).contains(old[start]) { start -= 1 }
        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > start, newEnd > start, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        if oldEnd < old.count, (0xDC00...0xDFFF).contains(old[oldEnd]) {
            oldEnd += 1
            newEnd += 1
        }
        return InputEdit(
            startByte: start * 2, oldEndByte: oldEnd * 2, newEndByte: newEnd * 2,
            startPoint: point(in: old, offset: start), oldEndPoint: point(in: old, offset: oldEnd),
            newEndPoint: point(in: new, offset: newEnd)
        )
    }

    private static func point(in units: [UInt16], offset: Int) -> Point {
        var row = 0
        var lineStart = 0
        for index in 0..<offset where units[index] == 10 {
            row += 1
            lineStart = index + 1
        }
        return Point(row: row, column: (offset - lineStart) * 2)
    }
}
