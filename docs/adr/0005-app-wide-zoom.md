# ADR 0005: Apply one persisted zoom to native and web presentation

- Status: Accepted (existing decision, documented retrospectively)
- Recorded: 2026-10-10

## Context

Increasing only terminal text leaves the rest of the app at a different scale. Scaling drawings without their layout bounds clips content or leaves unused preview space.

## Decision

Share a persisted `AppZoom` across windows at the supported levels from 50% to 200%. Command-plus/minus changes zoom and Command-0 resets it. Apply zoom once at each presentation root, including sheets and popovers, adjusting layout proposals and rendering together.

Keep the physical window size stable while content reflows. Native terminal rendering, editor geometry, and WebKit's logical viewport must agree with the scale. `FileContentHost` compensates retained host bounds for `viewportScale`. Hidden retained editors return zero requested size rather than relayout an invisible TextKit viewport. When the available height cannot hold usable terminal rows and surrounding panels, the workspace scrolls.

## Consequences

Test bounds, focus, split dragging, chooser scrolling, and preview viewport fill at both zoom extremes. Responsive tests should assert the desired invariant, not assume a sidebar always grows in one direction at every window size.

## Evidence

- [AppZoom](../../macOS/Twine/Twine/AppZoom.swift), [AppZoomLayout](../../macOS/Twine/Twine/AppZoomLayout.swift), [WorkspaceViewport](../../macOS/Twine/Twine/WorkspaceViewport.swift), [FileContentHost](../../macOS/Twine/Twine/FileContentHost.swift).
- [PR 87](https://github.com/aravind-n/twine/pull/87), [PR 140](https://github.com/aravind-n/twine/pull/140), [PR 141](https://github.com/aravind-n/twine/pull/141); project notes were used to locate these decisions and checked against current source/tests.
