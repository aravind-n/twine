# TwineSyntax

Native Tree-sitter syntax highlighting for Twine's AppKit editor. `SyntaxParser` owns its mutable C parser and incremental tree in an actor; only immutable UTF16 token ranges leave it. Supported grammars are Swift, Rust, Python, JSON/JSONC, JavaScript/JSX, TypeScript/TSX, TOML, YAML, and shell. Unknown files remain plain text.

Each snapshot is compared with the previous UTF16 snapshot to form one Tree-sitter edit. Byte offsets and line columns are derived from UTF16 code units, including CRLF and surrogate pairs. Query predicates are evaluated against the current snapshot. A sweep over capture boundaries produces sorted, non-overlapping runs; narrower captures win, followed by more specific capture names and later query patterns. Rendering does not mutate the document.

Parsing is limited to 2,097,152 UTF16 code units (enough for every file within Twine's 2 MiB UTF8 limit), 350 ms of native parsing, 350 ms of query traversal and normalization, and 100,000 captures. Exceeding a limit throws; the editor can fall back to plain text. Cancellation is checked before parsing, during native input reads, query traversal, and range normalization. The parser resets after work fails or is cancelled. The query deadline is cooperative: SwiftTreeSitter 0.10.0 does not expose the native cursor timeout, so a single native query step can finish after the deadline before the result is discarded. No small cursor match limit is set, because this wrapper cannot report silent match-limit truncation.

All dependencies use exact versions. SwiftTreeSitter's original `ChimeHQ/SwiftTreeSitter` URL redirects to the maintained `tree-sitter/swift-tree-sitter` repository. The pinned grammar manifests also use that URL, so retaining it prevents duplicate SwiftPM package identities. The Swift grammar uses its upstream `with-generated-files` release because the ordinary release intentionally omits the generated C parser. The tree-sitter runtime is pinned explicitly to 0.25.10, which supports the selected grammar ABIs. No JavaScript runtime, language server, network lookup, or grammar generation is required in the application.

The grammar queries and licenses are bundled under `Sources/TwineSyntax/Resources`. Queries are copied from these exact upstream versions:

| Component | Version | Upstream |
| --- | --- | --- |
| SwiftTreeSitter | 0.10.0 | https://github.com/tree-sitter/swift-tree-sitter |
| Tree-sitter runtime | 0.25.10 | https://github.com/tree-sitter/tree-sitter |
| Swift | 0.7.1-with-generated-files | https://github.com/alex-pinkus/tree-sitter-swift |
| Rust | 0.24.0 | https://github.com/tree-sitter/tree-sitter-rust |
| Python | 0.23.6 | https://github.com/tree-sitter/tree-sitter-python |
| JSON | 0.24.8 | https://github.com/tree-sitter/tree-sitter-json |
| JavaScript / JSX | 0.23.1 | https://github.com/tree-sitter/tree-sitter-javascript |
| TypeScript / TSX | 0.23.2 | https://github.com/tree-sitter/tree-sitter-typescript |
| TOML | 0.7.0 | https://github.com/tree-sitter-grammars/tree-sitter-toml |
| YAML | 0.7.0 | https://github.com/tree-sitter-grammars/tree-sitter-yaml |
| Bash | 0.23.3 | https://github.com/tree-sitter/tree-sitter-bash |

Local query adaptations: Rust integer and float captures use `number`, and the all-caps constant predicate fixes an upstream stray apostrophe and runs after the broader constructor rule; TOML's property capture covers only the key instead of the entire pair. TypeScript adds its query to the JavaScript query, and TSX also adds JSX. Shell highlighting is best effort for zsh, using the Bash grammar. Embedded languages inside strings or Markdown fences are not injected.

Parser tests live in `macOS/Twine/TwineTests/FileSyntaxParserTests.swift` and run through the repository's `make test-macos` / `make check-macos` targets. Follow `macOS/AGENTS.md` for changes to this package.
