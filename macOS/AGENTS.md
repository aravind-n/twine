# macOS app

Build the presentation layer with SwiftUI and AppKit. Keep workflow orchestration, PTYs, Git state, and persistence in the Rust backend. Send commands through the bridge and render the state, trace events, and terminal bytes it publishes.

Use SwiftTerm in an AppKit view for the primary terminal surface, with its Metal renderer enabled. Embed that view in SwiftUI and keep terminal I/O off the main actor.

Get backend state and send commands only through the Swift bridge client; build the Rust side of a feature alongside its UI rather than mocking it.

## Swift conventions

- **Language:** Swift 6 language mode with complete data-race checking and `MainActor` as the default isolation. Fix concurrency diagnostics with correct isolation or `Sendable` types, not with `@unchecked Sendable`, `nonisolated(unsafe)`, or `@preconcurrency`.
- **Platform:** The minimum supported version is macOS 26. Use macOS 26 APIs directly. Use APIs introduced after macOS 26 only behind `if #available`, with a macOS 26 fallback. Use standard controls and system materials so the app picks up the system design language.
- **State:** Use Observation: `@Observable` models with `@State`, `@Bindable`, and `@Environment`. Don't use `ObservableObject`, `@Published`, or Combine for app state.
- **Concurrency:** Use async/await and structured concurrency. Don't use GCD or Combine for new asynchronous work.
- **Tests:** Write unit tests with Swift Testing (`@Test`, `#expect`). Use XCTest only for UI tests.
- **Formatting and linting:** Format with `swift format --in-place --recursive macOS/` before committing; `swift format lint --strict --recursive macOS/` must pass. SwiftLint runs as part of every Xcode build, and its violations fail the build. The configs are `macOS/Twine/.swift-format` and `macOS/Twine/.swiftlint.yml`.
- **Logging:** Emit diagnostics with `Logger` from `os`, using the app's bundle identifier (`com.twineproject.Twine`) as the subsystem and one category per feature. Never use `print`. Never log secrets, file contents, or terminal output.

## Review

After changing Swift code, have the Swift reviewer agent (`swift-reviewer` in Claude Code, `swift_reviewer` in Codex) review the change, and address its findings before committing.
