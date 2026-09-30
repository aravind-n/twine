# Minimap studies

Open [minimap.html](minimap.html) directly in a browser. It is a standalone HTML prototype with no dependencies or network requests.

Three concepts share the same interactive Twine preview:

1. **The text landscape** — a persistent, VS Code-style overview of the transcript.
2. **A map with landmarks** — the overview plus anchored prompts, commands, failures, and completions. This is the suggested direction for agent workflows.
3. **The quiet edge** — a 14 px rail that expands over the output on hover, focus, or touch, intended for small windows and Bento panes.

Try the Terminal workflow, the two agent subtabs, and Bento. Each pane preserves its own scroll position. All concepts support click-to-jump, dragging the viewport, wheel scrolling, hover previews, arrow/Page Up/Page Down/Home/End keys, and Return to live. Search highlights matching lines in both the transcript and map; Enter or the arrow buttons navigates matches. Simulate output demonstrates following new output at the bottom while preserving a history position elsewhere. Both light and dark palettes follow `macOS/DESIGN.md`.

The output and event anchors are illustrative sample data. This prototype does not connect to live terminals or implement the feature in the native app. Production event markers should use recorded anchors and fall back to a plain text map when those anchors are unavailable. The overview represents transcript position, not elapsed time. An expanded compact rail overlays content to avoid changing terminal columns or wrapping during navigation.
