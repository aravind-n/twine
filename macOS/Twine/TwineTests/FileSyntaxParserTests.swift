import Foundation
import Testing
import TwineSyntax

struct FileSyntaxParserTests {
    @Test func languageDetectionUsesExtensionFilenameAndShebang() {
        #expect(SyntaxLanguage.detect(path: "Sources/main.SWIFT", source: "") == .swift)
        #expect(SyntaxLanguage.detect(path: "Cargo.toml", source: "") == .toml)
        #expect(SyntaxLanguage.detect(path: ".zshrc", source: "") == .bash)
        #expect(SyntaxLanguage.detect(path: "script", source: "#!/usr/bin/env -S python3 -u\n") == .python)
        #expect(SyntaxLanguage.detect(path: "script", source: "#!/bin/bash\n") == .bash)
        #expect(SyntaxLanguage.detect(path: "script", source: "#!/usr/bin/env node\n") == .javascript)
        #expect(SyntaxLanguage.detect(path: "notes.txt", source: "a python3 example") == nil)
        #expect(SyntaxLanguage.detect(path: "README.md", source: "# Swift") == nil)
        #expect(SyntaxLanguage.detect(path: "script", source: "#!/usr/bin/perl\n") == nil)
        #expect(SyntaxLanguage.detect(path: "sample.tsx", source: "") == .tsx)
    }

    @Test func everyBundledGrammarAndQueryProducesNativeTokens() async throws {
        let examples: [Example] = [
            .init(.swift, "let greeting = \"hello\" // comment\n", "let", .keyword),
            .init(.rust, "fn main() { let count = 42; }", "42", .number),
            .init(.python, "def greet():\n    return \"hello\"\n", "def", .keyword),
            .init(.json, "{\"greeting\": \"hello\", \"count\": 42}", "\"greeting\"", .property),
            .init(.javascript, "const greeting = \"hello\";", "const", .keyword),
            .init(.typescript, "const greeting: string = \"hello\";", "string", .type),
            .init(.tsx, "const view = <div title=\"hello\" />;", "div", .type),
            .init(.toml, "greeting = \"hello\"\n", "greeting", .property),
            .init(.yaml, "greeting: hello\n", "greeting", .property),
            .init(.bash, "if true; then echo \"hello\"; fi\n", "if", .keyword),
        ]
        let parser = SyntaxParser()
        for example in examples {
            let tokens = try await parser.highlight(example.source, language: example.language)
            let range = (example.source as NSString).range(of: example.sample)
            #expect(tokens.contains { $0.kind == example.kind && NSIntersectionRange($0.range, range) == range })
            expectValidRanges(tokens, source: example.source)
        }
    }

    @Test func predicatesDoNotTurnEveryJavaScriptVariableIntoAType() async throws {
        let source = "const lower = Upper; lower();"
        let tokens = try await SyntaxParser().highlight(source, language: .javascript)
        let lower = (source as NSString).range(of: "lower")
        let upper = (source as NSString).range(of: "Upper")
        #expect(tokens.contains { $0.range == lower && $0.kind == .variable })
        #expect(tokens.contains { $0.range == upper && $0.kind == .type })
    }

    @Test func rustConstantPredicateRecognizesAllCapsWithoutOverridingTypes() async throws {
        let source = "const MAX_COUNT: usize = 42; fn main() { let value = MAX_COUNT; let other = SomeType; }"
        let tokens = try await SyntaxParser().highlight(source, language: .rust)
        let declaration = (source as NSString).range(of: "MAX_COUNT")
        let reference = (source as NSString).range(of: "MAX_COUNT", options: .backwards)
        let type = (source as NSString).range(of: "SomeType")
        #expect(tokens.contains { $0.range == declaration && $0.kind == .keyword })
        #expect(tokens.contains { $0.range == reference && $0.kind == .keyword })
        #expect(tokens.contains { $0.range == type && $0.kind == .type })
    }

    @Test func incrementalEditsMatchFreshParsingAcrossUnicodeAndMultilineChanges() async throws {
        let parser = SyntaxParser()
        let snapshots = [
            "let emoji = \"🦊\"\r\nlet café = 42\r\n",
            "let emoji = \"🐈\"\r\nlet café = 42\r\n",
            "// 🐈\r\nlet emoji = \"🐈\"\r\nlet café = 42\r\n",
            "/* 🐈\r\nlet emoji = \"🐈\"\r\n*/\r\nlet café = 42\r\n",
            "let café = 42\r\n",
            "",
            "let replacement = \"👨‍👩‍👧‍👦\"\n",
        ]
        for source in snapshots {
            let incremental = try await parser.highlight(source, language: .swift)
            let fresh = try await SyntaxParser().highlight(source, language: .swift)
            #expect(incremental == fresh)
            expectValidRanges(incremental, source: source)
        }
    }

    @Test func utf16ReadBoundaryPreservesEmojiAndFollowingTokens() async throws {
        // The high surrogate falls at the end of the first 4096-byte read.
        let prefix = "const text = \""
        let source =
            prefix + String(repeating: "a", count: 2047 - prefix.utf16.count)
            + "🦊 café\";\r\nconst count = 42;"
        let tokens = try await SyntaxParser().highlight(source, language: .javascript)
        let lastKeyword = (source as NSString).range(of: "const", options: .backwards)
        let number = (source as NSString).range(of: "42")
        #expect(tokens.contains { $0.range == lastKeyword && $0.kind == .keyword })
        #expect(tokens.contains { $0.range == number && $0.kind == .number })
        expectValidRanges(tokens, source: source)
    }

    @Test func malformedSourceStillHighlightsAndRecoversAfterClosingComment() async throws {
        let parser = SyntaxParser()
        _ = try await parser.highlight("let value = \"unfinished", language: .swift)
        _ = try await parser.highlight("/* let value = 42\n", language: .swift)
        let source = "/* comment */\nlet value = 42\n"
        let tokens = try await parser.highlight(source, language: .swift)
        #expect(tokens.contains { $0.kind == .comment })
        #expect(tokens.contains { $0.kind == .keyword })
        #expect(tokens == (try await SyntaxParser().highlight(source, language: .swift)))
    }

    @Test func twoMiBASCIIFileRemainsEligibleForHighlighting() async throws {
        let suffix = "\nlet count = 42\n"
        let source = "//" + String(repeating: "a", count: 2_097_152 - 2 - suffix.utf16.count) + suffix
        let tokens = try await SyntaxParser().highlight(source, language: .swift)
        #expect(tokens.contains { $0.kind == .comment })
        #expect(tokens.contains { $0.kind == .keyword })
        #expect(tokens.contains { $0.kind == .number })
        expectValidRanges(tokens, source: source)
    }

    @Test func oversizedSourceFailsGracefullyAndParserCanBeReused() async throws {
        let parser = SyntaxParser()
        let oversized = String(repeating: "a", count: SyntaxParser.maximumUTF16Length + 1)
        await #expect(throws: SyntaxParserError.tooLarge) {
            try await parser.highlight(oversized, language: .swift)
        }
        let tokens = try await parser.highlight("let count = 1", language: .swift)
        #expect(tokens.contains { $0.kind == .number })
    }

    @Test func cancelledWorkDoesNotPublishTokens() async throws {
        let parser = SyntaxParser()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await parser.highlight("let count = 1", language: .swift)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!(try await parser.highlight("let count = 2", language: .swift)).isEmpty)
    }

    private struct Example {
        let language: SyntaxLanguage
        let source: String
        let sample: String
        let kind: SyntaxTokenKind

        init(_ language: SyntaxLanguage, _ source: String, _ sample: String, _ kind: SyntaxTokenKind) {
            self.language = language
            self.source = source
            self.sample = sample
            self.kind = kind
        }
    }

    private func expectValidRanges(_ tokens: [SyntaxToken], source: String) {
        var end = 0
        for token in tokens {
            #expect(token.range.location >= end)
            #expect(token.range.length > 0)
            #expect(NSMaxRange(token.range) <= source.utf16.count)
            #expect(Range(token.range, in: source) != nil)
            end = NSMaxRange(token.range)
        }
    }
}
