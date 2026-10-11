# ADR 0004: Use TextKit 2 editing and scoped WebKit previews

- Status: Accepted (existing decision, documented retrospectively)
- Recorded: 2026-10-10

## Context

The file browser needs editing with native selection, undo, IME, and keyboard behavior, plus rendered HTML/Markdown. Syntax colors must not change document contents or undo history.

## Decision

Use an AppKit `NSTextView` with TextKit 2 and SwiftTreeSitter-based highlighting. Track text edits and ranges in UTF-16; apply revision-checked rendering attributes independently of dirty/save/undo state. Do not access the legacy `layoutManager` to implement highlighting, because that can switch TextKit compatibility modes.

Use WebKit for rendered HTML and Markdown, while retaining Source editing. Markdown is parsed with `swift-cmark` GFM extensions. Serve generated preview resources through scoped synthetic URLs and canonical folder boundaries, preserving relative assets, heading fragments, and navigation. A preview is a rendering surface, not a replacement editor engine.

## Consequences

Unicode, stale parse results, scrolling, source/preview switching, relative links, and out-of-scope paths need dedicated coverage. Editor identity survives hiding. Native and web views require explicit viewport handling under app zoom (ADR 0005).

## Evidence

- [FileTextView](../../macOS/Twine/Twine/FileTextView.swift), [FileSyntaxHighlighter](../../macOS/Twine/Twine/FileSyntaxHighlighter.swift), [FileSyntaxRenderer](../../macOS/Twine/Twine/FileSyntaxRenderer.swift).
- [MarkdownRenderer](../../macOS/Twine/Twine/MarkdownRenderer.swift), [MarkdownAssetHandler](../../macOS/Twine/Twine/MarkdownAssetHandler.swift).
- [PR 85](https://github.com/aravind-n/twine/pull/85) and prior native-editor research notes, verified against current implementation. Rejected libraries' old licensing/activity assessments are intentionally not treated as permanent architectural facts.
