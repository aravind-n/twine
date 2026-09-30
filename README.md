# Twine

Twine is an agent workspace for coordinating your agents

## Files

Show the sidebar to browse the open folder. Expanding a directory loads only its children;
empty directories remain visible. The `twine-core` file watcher checks expanded directories and the
selected file every 500 ms, including changes made by shells and agents.

Select a file to make small edits to UTF-8 text up to **2 MiB**. Use **⌘Z** to undo, **⇧⌘Z** to
redo, **⌘S** to save, and **⌘L** to go to a line. Unsaved changes show “Edited” in the header.
Saves go through `twine-core` and check the disk version first. If it changed, choose **Reload** to discard
your edits or **Overwrite** to save them; **Cancel** keeps the edits without changing the file.
Disk updates refresh clean files and never replace unsaved edits. **⌘W** closes the file and returns to the
workflow. Binary files, larger files, deleted paths, symbolic links, and special files show
an explanatory state. Up to 256 directories can be expanded at once.

## Agent workflows

Choose **Adversarial**, **Coordinator**, or a stored custom workflow type from a new tab.
Pick a harness for each role instance and enter the workflow's prompt. Harnesses run directly
in the open folder; parallel workers receive their own sub-task and advisory file ownership.
Each role has a terminal subtab. A stage starts fresh harness processes, including when a review
loop returns to an earlier role.

Agents advance stages by invoking the private completion command included in their instructions.
The command accepts JSON on stdin: `decision` is `done`, `approve`, or `requestChanges`, with
a `summary` and, for assignment handoffs, `assignments` containing `role`, `instance`, `task`,
and `files`. Each invocation gets a new mailbox; submissions are atomic and limited to 64 KiB.
Rejected submissions can be corrected and resubmitted. Terminal prose and process exits never
advance a stage.

**Mark done…** is always available for an unfinished active role, including after its process
exits. Its form also supports review decisions and worker assignments. Review loops stop at the
type's limit; **Cancel workflow** stops all its agents. Runs restored after quitting or a crash
are interrupted, without automatically restarting harnesses. The Traces timeline records each
role's stage invocations. Select a span to inspect its stage changes, completions, and handoffs;
this history survives reopening the app.

Startup recovers interrupted work across all folders before publishing state. Agents retain their
individual lifecycle status, and unfinished trace spans gain a stopped event without changing
earlier events or transcript anchors. Completed and cancelled runs keep their outcomes. Recovery
requires exclusive ownership of the data directory; another live Twine core prevents startup.

The automated Rust suite uses fake harnesses for complete runs. To repeat the optional real
Adversarial smoke test with an authenticated Codex installation:

```sh
TWINE_REAL_CODEX="$(command -v codex)" cargo test -p twine-core \
  real_adversarial_workflow_completes -- --ignored
```

This test uses Codex's noninteractive mode in a disposable folder and verifies both agents'
explicit completion signals.

## Configuration

Twine reads `~/.config/twine/config.toml` at startup and creates a commented default file
on first launch. Settings are parsed and exposed to Swift, but do not change app behavior yet.

```toml
[appearance]
color_scheme = "system" # "system", "light", or "dark"
```

Omitted settings use defaults. Invalid TOML, invalid values, or file errors use the complete
defaults; unknown keys are ignored with a warning. Diagnostics include the file, line, and
key (or `<document>` when a syntax error has no identifiable key). They appear in macOS
Console under the `com.twineproject.Twine` subsystem, without logging config values.

Add settings as fields with defaults in `twine-core/src/config.rs`. The Serde schema drives
parsing, unknown-key warnings, the generated default file, and snapshot serialization;
extend Swift's `CoreConfig` when a consumer needs the new field.

## Terminal transcripts

`twine-core` records raw terminal output under `transcripts/` in its application data directory.
Terminal IDs remain unique across launches. Closing a terminal preserves output already accepted
for recording, and restored workflows start fresh terminals with new IDs.

Retention is capped at **64 MiB per terminal** and **512 MiB across all terminals**. Output is stored
in segments of at most **1 MiB**, with at most **512 segments** and **1,024 terminal metadata entries**.
Old segments or terminal entries expire when a limit is reached, so many short transcripts may
expire before the byte limit. Metadata and its atomic replacement are each capped at 1 MiB,
giving a maximum of **514 MiB of transcript file contents**, plus bounded filesystem overhead.
Pruned ranges remain expired after reopening.

`Application::read_terminal_transcript(terminal_id, offset, limit)` returns a page of exact bytes
starting at an absolute byte offset. Reads are limited to **64 KiB**. An offset at the recorded end
returns an empty page; an offset beyond that end is an error. Pruned history returns
`TranscriptRead::Expired` with the earliest retained offset, or `None` when no output remains.
Unknown IDs and unavailable storage return typed errors. Byte offsets do not describe terminal
screen state; ANSI replay and resize handling belong to the history viewer.

Click an anchored event in the trace details to select its workflow and agent and show a
read-only snapshot of the terminal at that moment. **Return to live** restores the agent's
live terminal. The snapshot replays cursor movement and recorded terminal sizes; resizing
the window only changes its viewport. It currently displays text without terminal colors
or images. Events without an anchor keep their details without a jump action.

Replay requires the entire byte prefix and its resize history. Pruned output, older
transcripts without geometry, or expired resize metadata show **Output no longer available**.
Resize metadata is bounded to 8,192 entries across transcripts and 256 pending entries per
terminal; losing geometry expires replay while preserving any retained raw output.

Recording uses a worker with at most **4 MiB / 256 requests** pending, plus one in-flight request.
The worker combines adjacent queued output from one terminal into batches up to **64 KiB**,
preserving read order while avoiding a separate durable commit for every small PTY read.
Backpressure pauses output readers without holding terminal input or application-state locks.
Storage failures leave live input and output usable and make transcript reads fail explicitly.
Reads wait for previously accepted output to commit and must run off the UI thread. Clean shutdown
flushes accepted recording; a crash may lose pending bytes. Reopening discards uncommitted tails
and orphan files, and reports damage to committed data instead of silently skipping it.

`Application::request_terminal_transcript` provides nonblocking admission and polling for the
history viewer. A full queue returns no request; polling a pending request returns no result,
so terminal input and live output polling can continue while disk reads are pending.

One core owns a transcript directory at a time; a second concurrent owner receives an explicit
error. The ownership lock is released after the recording worker has flushed and stopped.

## Development setup

- Install Xcode 27.0 and point the developer tools at it: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. The SwiftTerm build plugin and SwiftLint both require Xcode rather than the Command Line Tools.
- Install Xcode's Metal Toolchain if it is missing: `xcodebuild -downloadComponent MetalToolchain`.
- To build the library, install the latest stable Rust with `rustup`, then install both macOS targets: `rustup target add aarch64-apple-darwin x86_64-apple-darwin`.
- Build the framework once from the repository root: `make framework`.
- Open `macOS/Twine/Twine.xcodeproj`, select the `Twine` scheme, and build. Trust the SwiftTerm build plugin when Xcode prompts. Xcode consumes the prebuilt `TwineCore.xcframework` and does not invoke Cargo.

From the repository root, the root `Makefile` runs the same builds and checks from the command line. `make` lists every target:

```sh
make build-macos          # build the Debug framework, then the Debug app
make build-macos-release  # build the Release framework, then the universal Release app
make check                # Rust and Swift lint plus unit tests
make check-rust           # Rust only: rustfmt check, Clippy, workspace tests
make check-macos          # Swift only: swift-format lint, SwiftLint, unit tests
make fmt                  # format Rust and Swift
make ui-test-macos        # UI tests; they take over the desktop
make ui-test-macos ONLY='testFolderWindowInLightAppearance testFolderWindowInDarkAppearance'
make clean                # remove Cargo, framework, and Xcode build output
```

The generated framework includes its C header and module map and is ignored by Git. If the framework is missing, package resolution reports the command needed to create it.

`make build-macos-release` builds the universal Release app. Each build replaces the local framework with the Debug or Release profile it needs.

Linting prepares the framework before resolving the app's packages. `ONLY` accepts one UI test name or a quoted, space-separated list; omitting it runs the full UI suite.

SwiftLint runs the version pinned in `Package.resolved`, through `macOS/Twine/Scripts/swiftlint.sh`.
