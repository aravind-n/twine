import Testing

@testable import Twine

@MainActor
struct FileLineNumberTests {
    @Test func emptyAndTrailingLinesHaveNumbers() {
        #expect(FileLineIndex("").starts == [0])
        #expect(FileLineIndex("one").starts == [0])
        #expect(FileLineIndex("one\n").starts == [0, 4])
        #expect(FileLineIndex("\n\n").starts == [0, 1, 2])
    }

    @Test func lineNumbersUseUTF16AndTreatCRLFAsOneBreak() {
        let index = FileLineIndex("🌲 first\r\nsecond\n")
        #expect(index.starts == [0, 10, 17])
        #expect(index.number(startingAt: 0) == 1)
        #expect(index.number(startingAt: 10) == 2)
        #expect(index.number(startingAt: 17) == 3)
        #expect(index.number(startingAt: 2) == nil)
        #expect(index.number(startingAt: 18) == nil)
    }

    @Test func nativeLineSeparatorsAndWrappedContinuationsAreDistinct() {
        let index = FileLineIndex("a\rb\u{2028}c\u{2029}d")
        #expect(index.starts == [0, 2, 4, 6])
        #expect(index.number(startingAt: 3) == nil)
        #expect(index.number(startingAt: 6) == 4)
    }
}
