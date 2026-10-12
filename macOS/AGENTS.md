# macOS app

Build new presentation code with SwiftUI, using AppKit adapters for capabilities SwiftUI cannot provide. Keep native integrations with their owning subsystem's SwiftUI surface. Keep workflow orchestration, PTYs, Git state, and persistence in `twine-core`. Send it commands and render the state, trace events, and terminal bytes it publishes.

Use SwiftTerm in an AppKit view for the primary terminal surface, with its Metal renderer enabled. Embed that view in SwiftUI and keep terminal I/O off the main actor.

Get `twine-core` state and send commands only through `CoreClient`; build the `twine-core` side of a feature alongside its UI rather than mocking it.

The app links `twine-core` as the `TwineCore` XCFramework from the local `TwineCorePackage` binary Swift package. `make debug` and `make test-app` build the Debug framework first, and `make release` builds the Release framework first. Link only the package: keep build tooling, header paths, and direct static-library linkage out of the Xcode project.

## File placement

Organize Swift sources by subsystem ownership within the existing app target. Group each subsystem's views, presentation models, and native adapters together where they share behavior or invariants.

Keep `TwineApp.swift` as the only Swift source at the app source root, `Twine/Twine/`. Place every other app Swift file under its owning subsystem:

- `Windows/` owns folder-window composition, lifecycle, sidebar, and window layout; `Commands/` owns app menu commands.
- `Core/Client/` owns the Swift facade and event application, `Core/Transport/` owns worker actors and C ABI calls, and `Core/Protocol/` owns command, state, and wire representations.
- `Workflows/` owns workspace presentation, launch, designer, graph, and run controls. `Harnesses/` owns harness selection and model catalogs shared by workflow surfaces.
- `Terminal/`, `Files/`, `Traces/`, and `Memories/` own their respective surfaces, presentation state, and native adapters. `Settings/` owns the app settings presentation.
- `Design/` owns shared visual values, typography, and components; `Zoom/` owns app-wide zoom behavior. `Development/` owns checkout paths, inspection controls, and previews.

Apply these rules to every Swift change:

- Before adding, moving, or splitting a file, identify the responsibility it implements and reuse that owner's directory. Add a subsystem only for a distinct responsibility that existing owners do not cover.
- Add subdirectories when the current code has distinct internal responsibilities. Let each subsystem's needs determine its structure.
- Split files by independent responsibilities. Closely related types, representables and their coordinators, and small private helpers may share a file.
- Keep stored state and its private mutation helpers together. Group extensions by cohesive operations and preserve access control when splitting files.
- Put shared code in a directory named for the responsibility it provides when multiple subsystems use it. Keep subsystem-specific layout, formatting, and style values with their owner.
- Name files for their principal type or cohesive responsibility. Include destination directories and the types they will own in split or move proposals.
- Mirror ownership in the unit-test and UI-test targets based on the code under test. Core commands and wire contracts belong under `Core/`; window presentation checks belong under `Windows/`. Separate independent checks for different owners and put shared fixtures and doubles under `Support/`.
- When relocating files, preserve target membership, resource lookup, and development paths. Inspect source-relative paths such as `#filePath` and configured project references. Keep asset catalogs, documentation resources, and entitlements in their configured locations.

## Swift conventions

- **Language:** Swift 6 language mode with complete data-race checking and `MainActor` as the default isolation. Fix concurrency diagnostics with correct isolation or `Sendable` types, not with `@unchecked Sendable`, `nonisolated(unsafe)`, or `@preconcurrency`.
- **Platform:** The minimum supported version is macOS 26. Use macOS 26 APIs directly. Use APIs introduced after macOS 26 only behind `if #available`, with a macOS 26 fallback. Use standard controls and system materials so the app picks up the system design language.
- **State:** Use Observation: `@Observable` models with `@State`, `@Bindable`, and `@Environment`. Don't use `ObservableObject`, `@Published`, or Combine for app state.
- **Concurrency:** Use async/await and structured concurrency. Don't use GCD or Combine for new asynchronous work.
- **Tests:** Write unit tests with Swift Testing (`@Test`, `#expect`). Use XCTest only for UI tests.
- **Formatting and checks:** Run `make fmt-app` before committing, then `make check-app`. It runs strict swift-format lint, SwiftLint, and the unit tests, and must pass with no violations. The configs are `macOS/.swift-format` and `macOS/Twine/.swiftlint.yml`.
- **Logging:** Emit diagnostics with `Logger` from `os`, using the app's bundle identifier (`com.twineproject.Twine`) as the subsystem and one category per feature. Never use `print`. Never log secrets, file contents, or terminal output.

## UI testing and signing

- Run macOS UI tests from the repository root with `make ui-test`. `ONLY=<test>` runs one test, for example `make ui-test ONLY=testSingleAgentStartsInteractivelyTakesInputAndCancels`.
- Let Xcode use the project's default signing settings. `make ui-test` launches `TwineUITests-Runner` with Xcode's ad hoc "Sign to Run Locally" signature; an Apple Development identity isn't required. Avoid overriding signing with `CODE_SIGNING_ALLOWED=NO` or `CODE_SIGN_IDENTITY=-`. If a sandbox blocks Xcode's cache writes, rerun with access to the Xcode and SwiftPM caches.
- UI tests bring Twine to the foreground and control the desktop's pointer and keyboard. Tell the user before starting a run that will interrupt their desktop use. Check the final test result: a launched runner does not mean every test passed.

## Review

After changing Swift code, have the Swift reviewer agent (`swift-reviewer` in Claude Code, `swift_reviewer` in Codex) review the change. Include ownership and placement of every added, moved, or split Swift file in the review, and address its findings before finishing the work.
