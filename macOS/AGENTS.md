# macOS app

Build the presentation layer with SwiftUI and AppKit. Keep workflow orchestration, PTYs, Git state, and persistence in `twine-core`. Send it commands and render the state, trace events, and terminal bytes it publishes.

Use SwiftTerm in an AppKit view for the primary terminal surface, with its Metal renderer enabled. Embed that view in SwiftUI and keep terminal I/O off the main actor.

Get `twine-core` state and send commands only through `CoreClient`; build the `twine-core` side of a feature alongside its UI rather than mocking it.

The app links `twine-core` as the `TwineCore` XCFramework from the local `TwineCorePackage` binary Swift package. `make build-macos` and `make test-macos` build the Debug framework first, and `make build-macos-release` builds the Release framework first. Link only the package: keep build tooling, header paths, and direct static-library linkage out of the Xcode project.

## Swift conventions

- **Language:** Swift 6 language mode with complete data-race checking and `MainActor` as the default isolation. Fix concurrency diagnostics with correct isolation or `Sendable` types, not with `@unchecked Sendable`, `nonisolated(unsafe)`, or `@preconcurrency`.
- **Platform:** The minimum supported version is macOS 26. Use macOS 26 APIs directly. Use APIs introduced after macOS 26 only behind `if #available`, with a macOS 26 fallback. Use standard controls and system materials so the app picks up the system design language.
- **State:** Use Observation: `@Observable` models with `@State`, `@Bindable`, and `@Environment`. Don't use `ObservableObject`, `@Published`, or Combine for app state.
- **Concurrency:** Use async/await and structured concurrency. Don't use GCD or Combine for new asynchronous work.
- **Tests:** Write unit tests with Swift Testing (`@Test`, `#expect`). Use XCTest only for UI tests.
- **Formatting and checks:** Run `make fmt-macos` before committing, then `make check-macos`. It runs strict swift-format lint, SwiftLint, and the unit tests, and must pass with no violations. The configs are `macOS/.swift-format` and `macOS/Twine/.swiftlint.yml`.
- **Logging:** Emit diagnostics with `Logger` from `os`, using the app's bundle identifier (`com.twineproject.Twine`) as the subsystem and one category per feature. Never use `print`. Never log secrets, file contents, or terminal output.

## UI testing and signing

- Run macOS UI tests from the repository root with `make ui-test-macos`. `ONLY=<test>` runs one test, for example `make ui-test-macos ONLY=testSingleAgentStartsInteractivelyTakesInputAndCancels`.
- Let Xcode use the project's default signing settings. `make ui-test-macos` launches `TwineUITests-Runner` with Xcode's ad hoc "Sign to Run Locally" signature; an Apple Development identity isn't required. Avoid overriding signing with `CODE_SIGNING_ALLOWED=NO` or `CODE_SIGN_IDENTITY=-`. If a sandbox blocks Xcode's cache writes, rerun with access to the Xcode and SwiftPM caches.
- UI tests bring Twine to the foreground and control the desktop's pointer and keyboard. Tell the user before starting a run that will interrupt their desktop use. Check the final test result: a launched runner does not mean every test passed.

## Review

After changing Swift code, have the Swift reviewer agent (`swift-reviewer` in Claude Code, `swift_reviewer` in Codex) review the change, and address its findings before committing.
