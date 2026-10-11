# ADR 0001: Put workflow navigation in the titlebar and slim the closed bottom area

- Status: Accepted
- Recorded: 2026-10-10
- Provenance: User-approved revision 04 of the [interactive HTML specification](../design/compact-folder-chrome.html), based on main `1f514e0`.

## Context

The folder detail reserved a separate 42-point workflow row, a 34-point terminal strip, and large outer gaps. In Bento, the pane headers already identify each agent. The original collapsed bottom occupied 107 points. The user selected top option T3, retained rounded native surfaces, rejected the merged bottom/statusbar alternatives, and explicitly kept opened Traces at its original size.

## Decision

Use the native macOS toolbar for workflow **and file** tabs, new workflow, and workflow actions. Remove the duplicated visible folder title/path and workflow row from the detail. Preserve native window title metadata, traffic lights, sidebar toggle, fullscreen toolbar, and window dragging. macOS determines titlebar height; the HTML's 52 points is illustrative, not a promised saving.

Selected tabs remain rounded. At narrow widths or with many/long tabs, keep navigation in that same titlebar and provide an open-tabs menu with the full names. Never add a second workflow row. Preserve dirty-file indicators, close/unsaved-change handling, split commands, and keyboard shortcuts.

Move Individual mode, graph inspection, and Mark done into a Workflow menu, preserving their existing availability rules. Keep active cancellation directly available beside the Tabs/Bento control. At the minimum width or large zoom, use icon controls and put the layout choices in the Workflow menu to preserve direct Cancel and tab navigation. Bento removes the redundant global TERMINAL strip; its 28-point pane headers, 6-point gutters, 12-point terminal padding, focus ring, and retained terminal identities remain. Tabs keeps a 30-point agent selector where agent selection is needed. Single-agent workflows need no empty strip.

Keep Traces separate from the plain text status footer. Expose Show/Hide Traces in the View menu as well as its disclosure. Only the collapsed Traces surface becomes a 32-point capsule, with the familiar title at left and count/disclosure at right. Expanded Traces keeps its 48-point header, full body, controls, spacing, and detail behavior.

All dimensions below are logical points at 100% zoom:

| Component | Before | Accepted |
| --- | ---: | ---: |
| Detail top margin | 14 | 4 |
| Detail horizontal inset | 14 | 10 |
| Terminal to Traces gap | 13 | 6 |
| Closed Traces | 48 | 32 |
| Expanded Overview (header + body) | 48 + 224 | 48 + 224 |
| Expanded In Depth (header + body) | 48 + 384 | 48 + 384 |
| Traces to footer gap | 13 | 4 |
| Plain status footer | 22 | 20 |
| Bottom margin | 11 | 6 |
| Total closed bottom | 107 | 68 |
| Total Overview bottom | 331 | 308 |
| Total In Depth bottom | 491 | 468 |

The closed bottom saves 39 points; either expanded mode saves 23 points **outside** the Traces panel. Keep the terminal panel's 17-point radius and tiled panes' 11-point radius. Use system controls/materials, not HTML colors as a replacement native theme.

The footer places branch, workflow status, and elapsed time on the left and folder path on the right. Abbreviate the home directory and truncate the middle, preserving the final folder name. Clicking the path reveals the full selectable path and Copy Path; expose the same copy action in its context menu. Retain error/status visibility and full-text help.

## Consequences and acceptance

Toolbar space is finite: overflow is an intentional navigation path, and no important action should depend on a clipped control. Retained terminal/editor views must stay mounted across tab/layout changes. File and memory views, independent folder windows, keyboard focus, light/dark appearance, fullscreen, and app zoom from 50% to 200% remain supported. At tiny heights, scroll the workspace rather than shrink opened Traces or eliminate usable terminal rows.

Verify actual native geometry, not only CSS constants: closed header 32, opened header 48, Overview 272, In Depth 432, footer 20; navigation must be above the content viewport. Exercise overflow selection, file closing, Copy Path, tabs/Bento, cancellation and menu actions with real UI tests. Compare native screenshots with the approved HTML. The HTML's trace data and terminal text are illustrative; existing real trace semantics remain authoritative.

## Alternatives and guidance

A merged statusbar/trace drawer was rejected. Smaller expanded trace bodies were explicitly rejected. A second compact workflow row was superseded by T3.

[Apple's toolbar guidance](https://developer.apple.com/design/human-interface-guidelines/toolbars) informs concise, contextual native controls and accessible menu actions. [SwiftUI toolbar APIs](https://developer.apple.com/documentation/swiftui/toolbars) provide the native placement and title removal. These sources support the approach; the exact point dimensions are Twine's approved design decisions, not Apple requirements.
