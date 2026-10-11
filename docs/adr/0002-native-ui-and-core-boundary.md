# ADR 0002: Separate native presentation from the reusable application core

- Status: Accepted (existing decision, documented retrospectively)
- Recorded: 2026-10-10

## Context

Twine needs native macOS interaction while keeping workflow behavior independently testable and reusable. A bridge that accumulates domain logic would create a second application model.

## Decision

Use SwiftUI and AppKit for presentation. `twine-core` owns domain state and behavior: folders, sessions, workflows, PTYs, traces, transcripts, and configuration. `twine-bridge` adapts the plain Rust API to the C ABI and owns no separate domain state. Swift sends commands and observes snapshots, events, and terminal bytes only through `CoreClient`. Selected tabs, pane layouts, and form prefills belong to Swift presentation state.

Link the core through the local `TwineCore` XCFramework binary Swift package. Keep direct static-library linkage and build scripting out of the Xcode project. Use Swift 6 strict isolation and Observation for UI state; terminal I/O stays off the main actor.

## Consequences

Domain features require core implementation and tests rather than UI-only mock behavior. Cross-boundary changes must update their protocol and bridge together. Native UI and core can be tested independently; the extra boundary is deliberate.

## Evidence

- [Root architecture rules](../../AGENTS.md#architecture) and [macOS rules](../../macOS/AGENTS.md).
- [CoreClient](../../macOS/Twine/Twine/CoreClient.swift), [bridge](../../twine-bridge/src/lib.rs), and [framework packaging](../../macOS/TwineCorePackage/build.sh).
