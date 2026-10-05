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

    @Test func webAndAdditionalLanguageDetectionUsesConventionalPaths() {
        let paths: [(String, SyntaxLanguage)] = [
            ("index.html", .html), ("about.HTM", .html), ("page.xhtml", .html),
            ("site.css", .css), ("main.c", .c), ("shared.h", .c),
            ("main.cpp", .cpp), ("main.C", .cpp), ("shared.H", .cpp), ("shared.hpp", .cpp),
            ("main.cc", .cpp), ("main.cxx", .cpp), ("shared.hh", .cpp),
            ("Program.cs", .csharp), ("script.csx", .csharp), ("main.go", .go),
            ("Application.java", .java), ("script.rb", .ruby), ("project.gemspec", .ruby),
            ("Gemfile", .ruby), ("Rakefile", .ruby), ("Podfile", .ruby),
        ]
        for (path, language) in paths {
            #expect(SyntaxLanguage.detect(path: path, source: "") == language)
        }
        #expect(SyntaxLanguage.detect(path: "script", source: "#!/usr/bin/env ruby\n") == .ruby)
        #expect(SyntaxLanguage.detect(path: "script", source: "#!/usr/bin/jruby\n") == .ruby)
        #expect(SyntaxLanguage.detect(path: "main.php", source: "<?php") == nil)
        #expect(SyntaxLanguage.detect(path: "component.vue", source: "<template>") == nil)
    }

    @Test func everyBundledGrammarAndQueryProducesNativeTokens() async throws {
        let examples: [Example] =
            [
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
            ] + Self.additionalExamples
        #expect(Set(examples.map(\.language)) == Set(SyntaxLanguage.allCases))
        let parser = SyntaxParser()
        for example in examples {
            let tokens = try await parser.highlight(example.source, language: example.language)
            let range = (example.source as NSString).range(of: example.sample)
            #expect(tokens.contains { $0.kind == example.kind && NSIntersectionRange($0.range, range) == range })
            expectValidRanges(tokens, source: example.source)
        }
    }

    @Test func htmlHighlightsTagsAttributesValuesAndCommentsAfterEditing() async throws {
        let parser = SyntaxParser()
        let source = "<!-- 🦊 -->\n<main class=\"welcome\" data-count=\"42\">Hello</main>"
        let expected: [(String, SyntaxTokenKind)] = [
            ("<!-- 🦊 -->", .comment), ("main", .type), ("class", .property),
            ("welcome", .string), ("data-count", .property), ("42", .string),
        ]
        let tokens = try await parser.highlight(source, language: .html)
        for (sample, kind) in expected {
            let range = (source as NSString).range(of: sample)
            #expect(tokens.contains { $0.kind == kind && NSIntersectionRange($0.range, range) == range })
        }
        let edited = source.replacingOccurrences(of: "welcome", with: "updated-👨‍👩‍👧‍👦")
        let incremental = try await parser.highlight(edited, language: .html)
        #expect(incremental == (try await SyntaxParser().highlight(edited, language: .html)))
        expectValidRanges(incremental, source: edited)
    }

    @Test func additionalGrammarsRecoverFromIncompleteSource() async throws {
        for example in Self.additionalExamples {
            let parser = SyntaxParser()
            let incomplete = String(example.source.prefix(example.source.count / 2))
            let partial = try await parser.highlight(incomplete, language: example.language)
            #expect(!partial.isEmpty)
            expectValidRanges(partial, source: incomplete)
            let recovered = try await parser.highlight(example.source, language: example.language)
            let fresh = try await SyntaxParser().highlight(example.source, language: example.language)
            #expect(recovered == fresh)
            expectValidRanges(recovered, source: example.source)
        }
    }

    @Test func cppInheritsCKeywordsAndRubyLocalsKeepTheirVariableColor() async throws {
        let cpp = "class Greeter { public: int answer() { return 42; } };"
        let cppTokens = try await SyntaxParser().highlight(cpp, language: .cpp)
        let returnRange = (cpp as NSString).range(of: "return")
        #expect(cppTokens.contains { $0.range == returnRange && $0.kind == .keyword })
        #expect(cppTokens.contains { $0.kind == .number })
        let ruby = "message = \"hello\"\nmessage\n"
        let rubyTokens = try await SyntaxParser().highlight(ruby, language: .ruby)
        let declaration = (ruby as NSString).range(of: "message")
        #expect(rubyTokens.contains { $0.range == declaration && $0.kind == .variable })
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

    private static let additionalExamples: [Example] = [
        .init(.html, "<main class=\"welcome\">Hello</main>", "main", .type),
        .init(.css, ".welcome { color: #ff0000; margin: 12px; }", "color", .property),
        .init(.c, "int main(void) { return 42; }", "return", .keyword),
        .init(.cpp, "class Greeter { public: int answer() { return 42; } };", "class", .keyword),
        .init(.csharp, "class Greeter { public int Answer() { return 42; } }", "class", .keyword),
        .init(.go, "package main\nfunc greet() string { return \"hello\" }\n", "greet", .function),
        .init(.java, "public class Greeter { String greet() { return \"hello\"; } }", "class", .keyword),
        .init(.ruby, "def greet(name)\n  message = \"hello\"\n  message\nend\n", "def", .keyword),
    ]

    private struct Example: Sendable {
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
