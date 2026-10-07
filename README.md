<p align="center">
  <img src="macOS/Twine/Twine/Assets.xcassets/AppIcon.appiconset/twine-128.png" alt="Twine app icon" width="112" height="112">
</p>

<h1 align="center">Twine</h1>

<p align="center">A native macOS workspace for coordinating coding agents.</p>

<p align="center">
  <a href="https://github.com/aravind-n/twine/releases/latest">
    <img src="https://img.shields.io/github/v/release/aravind-n/twine" alt="Latest release">
  </a>
  <a href="https://github.com/aravind-n/twine/actions/workflows/ci.yml">
    <img src="https://github.com/aravind-n/twine/actions/workflows/ci.yml/badge.svg?branch=main&amp;event=push" alt="CI status on main">
  </a>
  <a href="#try-twine">
    <img src="https://img.shields.io/badge/macOS-26%2B-blue" alt="macOS 26 or later">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/github/license/aravind-n/twine" alt="MIT license">
  </a>
</p>

<p align="center">
  <a href="#about">About</a> ·
  <a href="#try-twine">Try Twine</a> ·
  <a href="https://aravind-n.github.io/twine/documentation/guide/">User guide</a> ·
  <a href="https://github.com/aravind-n/twine/issues">Feedback</a>
</p>

> [!NOTE]
> Twine is in early development. Features, integrations, and interfaces are still
> changing. Download a packaged release below, or build from source.

<p align="center">
  <img src="docs/assets/workspace.png" alt="Twine showing an Adversarial workflow with implementer and reviewer terminals and workflow traces">
</p>

## About

Twine brings your terminals, coding agents, files, and workflow history into one
macOS app. Open a folder, organize work into sessions, and choose how agents work
on a task: individually, in an implementation and review loop, or with a
coordinator assigning work to parallel workers.

You work directly with each agent in its terminal. Twine adds roles, handoffs,
and a record of what happened around the command-line tools you already use.
Each role can use a different harness and, where supported, a different model.

The macOS front end uses SwiftUI and AppKit, with the `twine-core` application library and
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for terminal emulation.

## What you can do today

- **Work in multiple folders.** Keep each folder in its own window with independent
  terminals and tabs, and restore open folders when Twine relaunches.
- **Work in terminals.** Run shells and agents, split a terminal into up to four
  panes, and paste images or drop files into a pane as paths.
- **Coordinate agents.** Use built-in Adversarial and Coordinator workflows with
  explicit completions and handoffs. Each role has its own terminal.
- **Define workflow types.** Add roles, instructions, stages, parallel roles,
  handoffs, and bounded review loops in the visual designer.
- **Follow the work.** Inspect workflow activity in Traces and jump to recorded
  terminal output where an anchor is available. Supported harness hooks add
  prompt, tool, and response events.
- **Return to earlier work.** Restore sessions, pane layouts, and retained
  terminal output. Resume a recorded harness conversation when its session
  handle is available.
- **Make small file edits.** Browse the open folder and edit UTF-8 text files up
  to 2 MiB, with native syntax highlighting, undo, and checks for changes made on
  disk before saving. Choose a language or Plain Text from the editor's language menu.
  Highlighting supports HTML/CSS, Swift, Rust, Python, JavaScript/TypeScript,
  C/C++/C#, Go, Java, Ruby, JSON, TOML, YAML, and shell files.

See the [user guide](https://aravind-n.github.io/twine/documentation/guide/) for detailed behavior and limits.

## Workflows

A **session** is a named body of work in a folder. Each top-level tab in that
session is a **workflow**. A workflow type defines how its agents are coordinated;
a **harness** is the external agent tool filling a role.

| Workflow type | How it works |
| --- | --- |
| Terminal | A plain shell, with optional split panes. |
| Single agent | One interactive coding agent. |
| Adversarial | An implementer does the task; a reviewer approves it or requests changes. Review loops are bounded. |
| Coordinator | A coordinator assigns sub-tasks to parallel workers, then gathers and checks their results. |
| Custom | Your own roles, stages, handoffs, and review loops, saved as a reusable workflow type. |

Agents advance a multi-agent workflow by submitting an explicit completion.
**Mark done…** also lets you submit a completion, review decision, or assignment
from the app. After completing an assignment, an agent's terminal remains
interactive for follow-up prompts.

Agents run directly in the open folder. Parallel file ownership is advisory;
Twine does not create isolated worktrees for workers.

## Supported harnesses

Twine currently has adapters for:

| Harness | Command on your shell's PATH |
| --- | --- |
| Codex | `codex` |
| Claude Code | `claude` |
| pi | `pi` |
| Antigravity | `agy` |
| OMP | `omp` |
| OpenCode v2 | `opencode` |

Install and authenticate the harnesses you want to use separately. Twine
discovers model choices from their CLIs; model and effort options depend on the
harness. Provider access and usage charges follow your harness configuration.
You can use Terminal workflows without installing an agent harness.

Traces opens in **Standard**, with steps in start order. **In depth** opens a
Timeline inspector for the selected step: tool intervals, parallel subagents,
search and failure filters, input/output previews, and jumps to recorded output.
Activity is saved with the session. The chart and inspector scroll independently.

| Harness | Tool detail | Native child activity |
| --- | --- | --- |
| Codex | Yes; failures only when explicitly reported | Subagents and their tools |
| Claude Code | Yes, including tool failures | Subagents and their tools |
| pi | Yes, including native nested tools | Depends on the custom subagent extension |
| OMP | Yes, including tool failures | Parallel/nested subagents and their tools |
| Antigravity | Lifecycle and workflow traces | Observer integration unavailable |
| OpenCode v2 | Lifecycle and workflow traces | Observer integration unavailable |

Observers are attached for one launch and do not change harness configuration.
OpenCode v2 and Antigravity currently require global/project/plugin configuration
for observers, so In depth explains the coverage limit. Older history keeps its
original events; Twine does not infer missing calls from terminal text.

Intervals use observed hook times. Missing or inverted endpoints remain incomplete;
previews are bounded to 2 KiB, with up to 10,000 activities per step. Resumed
subagents extend their native identity's lifetime rather than inventing invocation
boundaries. Codex does not provide parent-turn correlation for resumed children,
so their activity stays with the original observed step. Background children can
remain running after the parent responds. Compatibility depends on CLI versions;
see the [integration notes](https://aravind-n.github.io/twine/documentation/guide/#agent-workflows).

## Try Twine

Twine currently targets **macOS 26 or later**, on **Apple Silicon**.

Download `Twine-VERSION-macos-arm64.dmg` from the
[latest release](https://github.com/aravind-n/twine/releases/latest). Open the DMG
and drag **Twine** onto the **Applications** folder. Wait for the copy to finish,
eject the Twine disk image, and open Twine from Applications. New releases
are Developer ID signed and notarized. Older releases were ad hoc
signed and not notarized; follow the
[install notes](https://aravind-n.github.io/twine/documentation/guide/#install) for
first-launch approval.

Older releases, including v0.1.0, provide a ZIP. Until a stable DMG is published,
download that ZIP from the release page, extract it, and move `Twine.app` to
Applications.

Open a folder, create a session, and choose a workflow in a new tab. For an agent
workflow, choose the harness for each role, then enter your task in the first
agent's terminal.

### Build from source

To build from source, you will need:

- **Xcode 27.0**, selected as the active developer toolchain. Command Line Tools
  alone are insufficient for the app's build plugins.
- The **Xcode Metal Toolchain**. If missing, install it with
  `xcodebuild -downloadComponent MetalToolchain`.
- **Stable Rust**, installed through `rustup`.

```sh
git clone https://github.com/aravind-n/twine.git
cd twine
make debug
open out/debug/Build/Products/Debug/Twine.app
```

`make debug` builds the native app with debugging and incremental Swift compilation.
`make release` builds an optimized candidate at
`out/release/Build/Products/Release/Twine.app`, with no debug information or dSYM.
Rust output stays in Cargo's `target/`; macOS products, dependencies, tests,
packaging tools, and generated documentation live under `out/`.

Debug builds use `com.twineproject.Twine.development` and keep their database,
transcripts, layouts, attachments, and default configuration in `out/runtime/debug/`.
Test builds and results use `out/tests/` and separate preferences; temporary fixtures stay in the system temporary directory. `make clean` removes all generated
outputs and development/test state, including local Release candidates. It preserves
installed apps in `/Applications`, production data and configuration, and separate POC projects.
An explicit `TWINE_DATA_DIRECTORY`, `TWINE_CONFIG_PATH`, or `XDG_CONFIG_HOME` overrides the default location;
cleanup does not follow those overrides.

For editing in Xcode, first run `make debug`, then open
`macOS/Twine/Twine.xcodeproj` and select the **Twine** scheme. Run it again
after Rust changes. Use the Makefile for builds and tests to keep all outputs in `out/`.
Debug and Release select one generated local Swift package; run them sequentially.

Debug builds show the version and build number in the status bar, for example
`0.1.0 (42)`. CI assigns the build number from its workflow run number; release
packaging preserves that number. Local builds use the Xcode project's configured
build number and never increment it.

## Settings and saved work

Twine creates `~/.config/twine/config.toml` on first launch and reads it at startup.
For example:

```toml
[terminal]
font_family = "JetBrains Mono"
font_size = 13.0
```

Install the font in macOS, or omit `font_family` to use the system monospace font.
Restart Twine after editing settings. Appearance settings are parsed but are not
applied yet.

Application data is stored in `~/Library/Application Support/Twine`. Recorded
terminal output has retention limits of 64 MiB per terminal and 512 MiB overall,
with additional metadata limits. Older output can expire. Tracing is best effort,
and resuming work depends on the harness and its recorded session handle. See
[configuration](https://aravind-n.github.io/twine/documentation/guide/#configuration) and
[terminal transcripts](https://aravind-n.github.io/twine/documentation/guide/#terminal-transcripts).

## Development and feedback

The macOS front end lives in `macOS`, and the reusable application library lives in
`twine-core`. The `twine-bridge` adapter connects them through a C ABI.
The [development guide](https://aravind-n.github.io/twine/documentation/development/#development-setup)
describes the build and test setup; [CONTEXT.md](CONTEXT.md) defines the concepts
used throughout the codebase.

From the repository root:

```sh
make check          # Library and app formatting checks, lint, and unit tests
make fmt            # Format the library and the app
make ui-test        # Default UI suite; takes over the desktop
```

Bug reports, reproducible examples, and feedback on real workflows are welcome
in [GitHub Issues](https://github.com/aravind-n/twine/issues). Include your macOS,
Twine, and harness versions, what you expected, and what happened. For larger
contributions, open an issue to discuss the change before starting. Repository
guidance is in [AGENTS.md](AGENTS.md).

### GitHub Pages website

The GitHub Pages source lives in `docs/`: `index.html` is the home page,
`assets/` contains styles, scripts, and the screenshot, and `documentation/`
contains the documentation index and guides. Edit
`docs/documentation/guide/index.html` for the user guide and
`docs/documentation/development/index.html` for the development guide.
The `twine-core` reference is generated with
`cargo doc --workspace --no-deps`, using Cargo's bundled navigation and search.
The macOS app reference is generated with Xcode DocC and includes internal app symbols.

`make build-site` generates the API references and copies them, the static pages,
and the existing app icon and screenshot into `out/docs/site` for GitHub Pages.
Check in the static source files in `docs/`; the pipeline generates the API
references and publishing output, which are ignored by Git. The HTML is copied
unchanged. There is no website generator or Python dependency for the site.
Local assembly needs the macOS toolchain described above. `make docs-lib` and
`make docs-app` generate the API references separately. `make lint-ci`
lints the workflows and build scripts.

To enable hosting, select **GitHub Actions** under **Settings → Pages → Build and
deployment → Source**. Changes to the site on
`main` deploy to `https://aravind-n.github.io/twine/`. Rust and Swift source changes
also regenerate their API references. Pull requests build the site without
deploying it. Builds use the existing `xcode-27` runner; deployment runs on a
GitHub-hosted Ubuntu runner. No custom domain or additional secrets are required.

## Acknowledgments

Thank you to [AI Tinkerers Seattle](https://seattle.aitinkerers.org/) for the
opportunity to demo and premiere Twine.

Twine's terminal emulation uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

## License

Twine is available under the [MIT License](LICENSE).
