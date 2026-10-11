# ADR 0003: Isolate folder runtimes and retain live terminal surfaces

- Status: Accepted (existing decision, documented retrospectively)
- Recorded: 2026-10-10

## Context

Users work in several folders and switch among workflows, agents, and files. Recreating a runtime or terminal during navigation can stop processes, lose terminal state, or route commands to the wrong folder.

## Decision

Each folder window has its own runtime, `CoreClient`, tab state, and command routing. Opening an already-open folder focuses that window. Restore folder windows across launches, retaining the identity of unavailable folders. Share app settings and durable history without allowing one window's closure to shut down another window's active resources.

Keep workflows and their terminal emulators/output pumps mounted until they close. Switching workflows, Tabs/Bento, or pane focus changes visibility and geometry, not shell identity. Distinguish selected/focused, visible, and retained hidden states. Retain file editors and undo state similarly, while hidden native editors avoid unnecessary layout.

## Consequences

Hidden views need explicit hit-testing, accessibility, focus, and layout behavior. Lifecycle tests must verify shell identity/output and independent window closure, not merely the selected tab's appearance. Shutdown awaits persistence and closes only the intended resources.

## Evidence

- [FolderWindows](../../macOS/Twine/Twine/FolderWindows.swift), [FolderWindowRoot](../../macOS/Twine/Twine/FolderWindowRoot.swift), [TwineApp termination](../../macOS/Twine/Twine/TwineApp.swift).
- [WorkflowPaneCanvas](../../macOS/Twine/Twine/WorkflowPaneCanvas.swift), [AgentPanes](../../macOS/Twine/Twine/AgentPanes.swift), [FileTextView](../../macOS/Twine/Twine/FileTextView.swift).
- Historical delivery: [PR 84](https://github.com/aravind-n/twine/pull/84), [PR 86](https://github.com/aravind-n/twine/pull/86). Prior project notes located these decisions; the current source was checked before recording them.
