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
  <a href="#install">
    <img src="https://img.shields.io/badge/macOS-26%2B-blue" alt="macOS 26 or later">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/github/license/aravind-n/twine" alt="MIT license">
  </a>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="https://aravind-n.github.io/twine/documentation/guide/">User guide</a> ·
  <a href="#contributing">Contributing</a>
</p>

Twine is the terminal-first collaboration layer for AI coding agents.
Bring agents together through controlled workflows, visual traces, and cross-agent memory.

## Install

Twine requires **macOS 26 or later** on **Apple Silicon**.

Install it with [Homebrew](https://brew.sh):

```sh
brew install --cask twineproject/tap/twine-app
```

Then open Twine from Applications.

To install manually instead, download the `.dmg` from the
[latest release](https://github.com/aravind-n/twine/releases/latest), open it,
and drag **Twine** onto **Applications**.

To update a manual install, see the
[install notes](https://aravind-n.github.io/twine/documentation/guide/#install).

Agent workflows also need at least one [supported harness](#supported-harnesses)
installed and signed in. Terminal workflows need nothing else.

## Quick start

This takes about a minute and needs no agent harness.

1. Open Twine and choose **Open Folder…** (⌘O). Pick any project folder.
2. Create a session. A session groups the work for one task.
3. Add a workflow in a new tab and choose **Terminal**.
4. Run a command in the terminal, for example `git status`.

You should see the command's output in the terminal and one step for that
command in the Traces panel. Selecting the step jumps to its output.

To run your first agent workflow, add another tab and choose **Adversarial**.
Pick a harness for the implementer and for the reviewer, start the workflow, and
type a task in the implementer's terminal. When the implementer submits its
completion, the reviewer's terminal receives the work and either approves it or
sends changes back.

## Usage

A **session** is a named body of work in a folder. Each top-level tab in a
session is a **workflow**, created from a **workflow type**:

| Workflow type | How it works |
| --- | --- |
| Terminal | A plain shell, with optional split panes. |
| Single agent | One interactive coding agent. |
| Adversarial | An implementer does the task; a reviewer approves it or requests changes. |
| Coordinator | A coordinator assigns sub-tasks to parallel workers, then gathers and checks their results. |
| Custom | Your own roles, stages, handoffs, and review loops, built in the visual designer. |

Common tasks, each covered in the
[user guide](https://aravind-n.github.io/twine/documentation/guide/):

- **Advance a workflow yourself.** Use **Mark done…** to submit a completion,
  review decision, or assignment on an agent's behalf. See
  [agent workflows](https://aravind-n.github.io/twine/documentation/guide/#agent-workflows).
- **Split a terminal** into up to four panes, and paste images or drop files
  into a pane as paths. See
  [terminal panes](https://aravind-n.github.io/twine/documentation/guide/#terminal-panes).
- **Browse and edit files** in the open folder with syntax highlighting. See
  [files](https://aravind-n.github.io/twine/documentation/guide/#files).
- **Change the terminal font** in **Twine → Settings…** (⌘,), which edits
  `~/.config/twine/config.toml` and applies changes on save. See
  [configuration](https://aravind-n.github.io/twine/documentation/guide/#configuration).

  ```toml
  [terminal]
  font_family = "JetBrains Mono"
  font_size = 13.0
  ```

- **Inspect recorded agent activity** in **Traces → In Depth**. Overview shows
  activity counts and an **Inspect activity** action. LLM calls include public
  responses/summaries, model and usage details when the harness supplies them;
  missing timings or request bodies remain marked as unrecorded. **Show full
  details** opens complete saved inputs and results.
  The storage control shows usage, pins a step, and clears completed, unpinned
  details. Twine keeps compact metadata in SQLite and deduplicates large details
  in adjacent files. Active steps and pinned details can exceed the cache budget.
  Native harness files remain untouched.

  ```toml
  [traces]
  detail_budget_mb = 512
  retention_days = 90 # Closed, unpinned workflows; 0 disables age expiry.
  ```

  Saved Codex, Claude Code, Pi, and OMP conversations can recover activity for
  their linked steps. Recovery uses native IDs or an unambiguous prompt/time
  match within the same conversation. It cannot recover data absent from both
  the observer and native history. OpenCode and Antigravity use live observers.

### Supported harnesses

A **harness** is the external agent CLI that fills a role. Twine finds each one
by its command on your shell's `PATH`:

| Harness | Command | Prompt and tool detail in Traces |
| --- | --- | --- |
| Codex | `codex` | Yes |
| Claude Code | `claude` | Yes |
| pi | `pi` | Yes |
| OMP | `omp` | Yes |
| Antigravity | `agy` | Yes; model invocation details where exposed |
| OpenCode v2 | `opencode` | Yes |

Install and authenticate harnesses separately. Model choices come from each
harness's own CLI, and provider access and usage charges follow your harness
configuration. Twine never edits your harness config files.

## Project status

Twine is in **early development**. It is usable day to day, but features,
integrations, and saved formats can change between releases, and there are no
stability guarantees yet. The [changelog](CHANGELOG.md) lists what changed in
each release.

Known limitations:

- Agents run directly in the open folder. Twine does not create worktrees or
  sandboxes, and file ownership between parallel workers is advisory.
- Twine is an interactive desktop app. It does not run workflows unattended or
  headless.
- Harness support depends on CLI versions, and a harness update can break an
  integration until Twine catches up.
- Tracing is best effort. Recorded terminal output is capped at 64 MiB per
  terminal and 512 MiB overall, so older output can expire.
- Resuming a conversation depends on the harness recording a session handle.

## Contributing

Bug reports and feedback on real workflows are welcome in
[GitHub Issues](https://github.com/aravind-n/twine/issues). Include your macOS,
Twine, and harness versions, what you expected, and what happened. For larger
changes, open an issue to discuss the idea before you start. Changes reach
`main` through pull requests.

### Build from source

You will need:

- **Xcode 27.0**, selected as the active developer toolchain. Command Line Tools
  alone are not enough.
- The **Xcode Metal Toolchain**: `xcodebuild -downloadComponent MetalToolchain`.
- **Stable Rust**, installed through [rustup](https://rustup.rs).

```sh
git clone https://github.com/aravind-n/twine.git
cd twine
make debug
open out/debug/Build/Products/Debug/Twine.app
```

Debug builds keep their data in `out/runtime/debug/`, separate from an installed
copy of Twine.

### Check your changes

```sh
make fmt      # format the library and the app
make check    # lint and unit-test the library and the app
make          # list every target
```

`make ui-test` runs the UI suite and takes over the desktop while it runs.

### Find your way around

| Path | Contents |
| --- | --- |
| `macOS/` | The SwiftUI and AppKit front end. |
| `twine-core/` | The Rust application library that owns behavior and saved state. |
| `twine-bridge/` | The C ABI adapter between the two. |
| `docs/` | Source for the [website and guides](https://aravind-n.github.io/twine/). |

The [development guide](https://aravind-n.github.io/twine/documentation/development/)
covers setup, harness integration, and releases.
[CONTEXT.md](CONTEXT.md) defines the terms used in the code and UI, and
[AGENTS.md](AGENTS.md) holds the repository conventions.

## Security

Please report vulnerabilities privately through
[GitHub security advisories](https://github.com/aravind-n/twine/security/advisories/new)
instead of a public issue.

## Acknowledgments

Thank you to [AI Tinkerers Seattle](https://seattle.aitinkerers.org/) for the
opportunity to demo and premiere Twine. Twine's terminal emulation uses
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

## License

Twine is available under the [MIT License](LICENSE).
