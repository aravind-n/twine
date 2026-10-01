# Twine

Twine is an agent workspace for coordinating your agents

## Install

Download the universal ZIP from [GitHub Releases](https://github.com/aravind-n/twine/releases).
It supports Apple Silicon and Intel on **macOS 26+**. Extract it, move `Twine.app` to
Applications, and follow its included `README.txt`. If macOS blocks the first launch,
use **System Settings → Privacy & Security → Open Anyway** for Twine, then confirm Open.
The app is ad hoc signed and not notarized; managed Macs may restrict approval.

## Files

The sidebar starts open. Toggle it with the toolbar button or **⌃⌘S** to browse the folder or make more room for terminals. Expanding a directory loads only its children;
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
Pick a harness for each role instance, and optionally its model and effort level, then start it.
Supported harnesses are Codex, Claude Code, pi, Antigravity (`agy`), OMP (`omp`), and OpenCode (`opencode`), installed on your shell's PATH.
Twine reads each harness's models from its own CLI (`codex debug models`, `pi --list-models`, `agy models`, `omp models --json`, `opencode api model.list`, and
the aliases in `claude --help`); Claude Code also takes any typed model name. A YOLO checkbox skips
the harness's permission prompts (`--dangerously-bypass-approvals-and-sandbox` for Codex,
`--dangerously-skip-permissions` for Claude Code and Antigravity, `--auto-approve` for OMP); pi doesn't ask for permission, so it has none. The first stage's agent asks for the task in
its terminal and reports it when it finishes, so later roles receive it. Harnesses run directly
in the open folder; parallel workers receive their own sub-task and advisory file ownership.
Each role has a terminal subtab. A stage starts fresh harness processes, including when a review
loop returns to an earlier role.

Choose **Create your own** (**⌥⌘N**) in a new tab to design a workflow type. Add roles and
instructions, order stages and their parallel roles, connect handoffs, and bound review loops.
The designer shows validation errors beside each affected element and enables Save only after
the current design validates. Use Tab and Shift-Tab to navigate controls, Return to save, and
Escape to cancel. The Preview tab shows the graph.

From a type's launch form, **Edit workflow type** or **Edit a copy** (**⇧⌘E**) opens the designer.
Saving a built-in creates a custom copy. Editing a custom type adds a version; workflows already
started keep their original version. Saved types appear in the catalog and survive relaunch.

Agents advance stages by invoking the private completion command included in their instructions.
The command accepts JSON on stdin: `decision` is `done`, `approve`, or `requestChanges`, with
a `summary` and, for assignment handoffs, `assignments` containing `role`, `instance`, `task`,
and `files`. Until the task is known, the first completion must also include `task`. Each invocation gets a new mailbox; submissions are atomic and limited to 64 KiB.
Rejected submissions can be corrected and resubmitted. Terminal prose and process exits never
advance a stage.

**Mark done…** is always available for an unfinished active role, including after its process
exits. Its form also supports review decisions and worker assignments. Review loops stop at the
type's limit; **Cancel workflow** stops all its agents. Runs restored after quitting or a crash
resume their unfinished active agents when every one has a recorded harness session. Otherwise they remain interrupted with their saved output. The Traces panel shows each
role's stage invocations on compact agent tracks in shared start order, with equal spacing
regardless of pauses. Select a step to focus a seven-step window and inspect its stage
changes, completions, and handoffs; this history survives reopening the app.

Claude Code, Codex, pi, and OMP also report prompts, tool calls, and responses through launch-only observers.
Single-agent runs show a span for each prompt; multi-agent steps stay under the role's assignment.
Select a step to jump to its recorded terminal position. Hook payloads are bounded and recording
is best effort. If hooks are unavailable or disabled, the ordinary agent span remains. User and
project harness config files are never edited. Codex hook compatibility is verified with CLI
0.159; Twine trusts only its own invocation hooks and preserves existing hook policy.
Pi uses a temporary extension supplied with `--extension`, verified with pi 0.99.1. It observes
prompts as they enter the agent (including queued prompts), tool execution, and final response
settlement. Delivery never waits on Twine, and user/project extensions remain enabled.
Antigravity uses `--prompt-interactive` for initial tasks and keeps its terminal open for follow-up
prompts. It retains lifecycle and workflow spans; per-prompt and tool observers aren't installed
because `agy` doesn't expose a launch-only hook option. Its models and effort levels are discovered
from `agy models` and `agy --help`, verified with agy 1.2.5 and 1.2.14.
OMP uses an explicit `launch` subcommand and literal positional prompts. Its JSON catalog supplies
provider groups and model-specific thinking levels; typed model selectors and aliases also work.
Thinking options come from `omp --help` and use `--thinking`. OMP shares the temporary observer
extension with pi, using OMP's continuation-aware `agent_end` event and observing only the root
agent, verified with OMP 18.4.5. User and folder extensions remain enabled.
OpenCode v2 uses `mini --standalone`, keeping its interactive terminal and private server within
the agent's lifetime. Initial tasks use `--prompt`; model-specific effort choices select the model's
named variant with `--model provider/model#variant`. Its CLI API supplies model names, provider
groups, and variants for the open folder; catalogs are cached per folder. Custom selectors can
include other variant names. The mini interface
has no auto-approve or temporary-plugin flag, so YOLO is unavailable and it retains lifecycle
and workflow spans. Compatibility is verified with OpenCode 2.0.21.

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

To verify the installed Codex's actual prompt/tool/response hooks and terminal anchors:

```sh
TWINE_REAL_CODEX="$(command -v codex)" make test-rust \
  RUST_TEST_ARGS='real_codex_records_tool_steps -- --ignored'
```

This opt-in test uses interactive, authenticated Codex in a disposable folder with a read-only sandbox.

To verify pi's interactive trace events using both DeepSeek Flash and DeepSeek V4 Pro:

```sh
TWINE_REAL_PI="$(command -v pi)" make test-rust \
  RUST_TEST_ARGS='real_pi_deepseek_models_record_tool_steps -- --ignored'
```

This opt-in test uses your existing DeepSeek authentication, disposable folders, and the bash tool
to print a marker. It does not edit pi settings or save sessions.

The extension's queued-prompt, tool-correlation, Unicode, and unavailable-endpoint checks need only Node:

```sh
TWINE_NODE="$(command -v node)" make test-rust \
  RUST_TEST_ARGS='pi_extension_preserves_queued_prompts_and_tool_identity -- --ignored'
```

## Configuration

Twine reads `~/.config/twine/config.toml` at startup and creates a commented default file
on first launch. Restart Twine after editing settings.

```toml
[appearance]
color_scheme = "system" # "system", "light", or "dark"

[terminal]
font_family = "JetBrains Mono"
font_size = 13.0
```

Terminal settings apply to live shell and agent terminals, including Bento panes, and terminal
history. Install the font in macOS and use its family name. An omitted or empty `font_family`
uses system monospace. Twine checks that `i` and `w` have equal character widths, allowing Nerd
Fonts whose icons are wider. An unavailable font or one that fails this check falls back to
system monospace with a warning. `font_size` defaults to 13 points and accepts sizes from 6
through 72, including fractional sizes such as 13.5. Appearance settings are parsed but are
not applied yet.

Terminal colors use the Silica palette in dark mode and an adapted palette in light mode.

Omitted settings use defaults. Invalid TOML, invalid values, or file errors use the complete
defaults; unknown keys are ignored with a warning. Diagnostics include the file, line, and
key (or `<document>` when a syntax error has no identifiable key). They appear in macOS
Console under the `com.twineproject.Twine` subsystem, without logging config values.

Add settings as fields with defaults in `twine-core/src/config.rs`. The Serde schema drives
parsing, unknown-key warnings, the generated default file, and snapshot serialization;
extend Swift's `CoreConfig` when a consumer needs the new field.

## Terminal panes

Use the two buttons at the top right, **⌘D** to split right, or **⇧⌘D** to split down.
Each split starts a shell in the same folder; run any command or coding agent there.
Up to four panes share the same Bento styling and draggable dividers as agent workflows.
**⌘[** and **⌘]** move keyboard focus. Each pane has a close button; **⌘W** closes the focused
pane, and closing the tab closes its panes. Pane layouts survive reopening. The Traces panel combines
all panes in a tab into one set of tracks, and selecting an event focuses its owning pane.

Paste a clipboard screenshot with **⌘V**, or drop images and files onto any terminal or agent
pane. Clipboard images become private PNG files in the temporary directory; Twine inserts their
quoted paths so the shell or harness can read them. File drops use their original paths.
Codex launches with `--no-alt-screen` and pi with `--tui-mode regular` so output remains in
scrollback. Claude Code, OMP, and OpenCode's mini interface already render inline; harnesses
without an inline launch option retain their own display setting.

## Terminal transcripts

Every terminal and agent pane has a compact minimap at its right edge. Hover or focus the
14-point rail to expand it over the output; expansion does not change the terminal's columns.
Click or drag the visible-region indicator to scroll. With the rail focused, use the arrow,
Page Up/Down, Home, and End keys. **Return to live** resumes following the latest output.
Each Bento pane keeps its own position.

Minimap points use the same step IDs, numbers, role colors, and selection as **Traces**.
Selecting a point opens that step in Traces and scrolls the live terminal to its recorded
position. Points are placed by terminal row;
the Traces panel spaces steps by start order. Loading **Older traces** adds those steps to the
map when their output is still available. Output without an available anchor remains
scrollable without a guessed point. Historical output also has its own minimap.

`twine-core` records raw terminal output under `transcripts/` in its application data directory.
Terminal IDs remain unique across launches. Closing a terminal preserves output already accepted
for recording. Reopening a folder restores recorded output and scrollback. Shells append a fresh
prompt. Single agents resume their exact recorded harness session, retaining earlier output.
Codex and Claude Code use session IDs; pi and OMP use session files. Antigravity and OpenCode
support exact-ID resume but don't expose launch observers, so use **Resume Session…** to supply
the conversation/session ID once. The same action is available for older tabs without a captured
session. Twine never guesses the latest conversation. Cancelled or failed agents remain stopped.
**Saved output** opens earlier invocations, including an idle shell with no trace step.
Live views and ANSI replay retain up to 100,000 rows in memory; the raw transcript limits below
apply independently. Draft launch surfaces do not create trace lanes until used as terminals.

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

Click an anchored event in trace details to select its workflow and agent and scroll the mounted
terminal to that point. **Return to live** scrolls back to the latest output. If a point belongs
to an earlier invocation or has left scrollback, choose **Show saved output** in the notice to
open a read-only snapshot. Saved output replays cursor movement and recorded terminal sizes;
resizing the window only changes its viewport. It displays text without terminal colors or
images. Events without an anchor keep their details without a jump action.

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
make ui-test-macos        # 12 default UI tests; they take over the desktop
make ui-test-macos-all    # all UI tests, including retired tests and the launch benchmark
make ui-test-macos-visual # optional appearance and screenshot checks
make ui-test-macos ONLY='testFolderWindowInLightAppearance testFolderWindowInDarkAppearance'
make ui-test-macos ONLY=testLaunchPerformance
make clean                # remove Cargo, framework, and Xcode build output
```

The generated framework includes its C header and module map and is ignored by Git. If the framework is missing, package resolution reports the command needed to create it.

`make build-macos-release` builds the universal Release app. Each build replaces the local framework with the Debug or Release profile it needs.

Linting prepares the framework before resolving the app's packages. The default UI suite runs the 12 tests listed in `UI_DEFAULT_TESTS` in the Makefile. The other 34 tests are retired from default runs; their source stays in place and they still build. Add a test to `UI_DEFAULT_TESTS` to re-enable it by default.

`ONLY` accepts one UI test name or a quoted, space-separated list, including retired tests, and overrides the default selection. `make ui-test-macos-all` runs all 46 UI tests, including the appearance checks and launch benchmark. `make ui-test-macos-visual` runs the optional visual checks.

CI uses the same default selection through `make ui-test-macos-built`, which reuses its existing build-for-testing products; set `UI_TEST_DERIVED_DATA` to their DerivedData directory. Add `ALL=1` to that command to run the full suite using those products. An explicit `ONLY` selection takes precedence over `ALL=1`. All UI test runs take over the desktop.

SwiftLint runs the version pinned in `Package.resolved`, through `macOS/Twine/Scripts/swiftlint.sh`.

## Releases

Pushing a `vMAJOR.MINOR.PATCH` tag runs `.github/workflows/release.yml` and creates a
**draft** GitHub Release. It reuses the unsigned universal build from successful main CI
for that commit, or rebuilds it using the same build workflow if the artifact has expired.
No Apple Developer account, signing certificate, notarization credentials, or release
secrets are required.

To cut a release:

1. Set the version in `Cargo.toml` and update `Cargo.lock`. Set the Twine app's
   **Marketing Version** in both Debug and Release configurations to the same version.
2. Move the finished changelog entries into a dated section such as
   `## [0.1.0] - 2026-09-30`, leaving `[Unreleased]` above it. The release body comes from
   exactly that section, following the same extraction as vhrn. Missing, empty, or duplicate
   sections fail the release.
3. Review and merge through a pull request. Wait for push-to-main CI on that commit to pass.
4. Create and push the tag on that reviewed main commit:

   ```sh
   git tag -a v0.1.0 <reviewed-main-commit> -m 'Twine 0.1.0'
   git push origin v0.1.0
   ```

5. Wait for Release to finish. Download the draft ZIP, check its checksum, and test first
   launch on a Mac with quarantine enabled using the included instructions. Check a shell
   and the harnesses you intend to support, then publish the draft in GitHub Releases.

The release contains:

- `Twine-VERSION-macos-universal.zip`: ad hoc signed app, install README, and license.
- `libtwinecore-VERSION-macos-universal.tar.gz`: the existing universal static C ABI library
  as `libtwinecore.a`, matching C header, usage README, and license.
  The protocol is experimental; pin matching header/library versions.
- `twine-VERSION-source.tar.gz`: the tagged Git source tree.
- `Twine-VERSION-symbols.tar.gz`: app debug symbols, checked against both executable UUIDs.
- `SHA256SUMS`: SHA-256 checksums for all four archives.

The packaged app's short version and bundle version both match the tag. Its ad hoc signature
provides integrity; users still approve the first launch themselves. No DMG or notarization
is involved. This release matrix is macOS only.

Re-run failed jobs to retry a draft release. Published releases are never overwritten; use
a new patch version for a correction after publication. Do not move an existing release tag.

For local packaging, run from the root (the output directory must be empty):

```sh
make check-release  # needs shellcheck and actionlint
make build-macos-release XCODE_BUILD_ARGS=CODE_SIGNING_ALLOWED=NO
make release-bundle
make release-package VERSION=0.1.0
(cd dist && shasum -a 256 -c SHA256SUMS)
```

`DERIVED_DATA`, `BUILD_DIR`, `BUNDLE_DIR`, and `OUTPUT_DIR` can override the default paths.
These commands do not create a GitHub Release. The source archive always uses committed HEAD.
