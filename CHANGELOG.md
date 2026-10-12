# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Show Git changes directly in Files, including staged and unstaged edits,
  untracked files, renames, deletions, and conflicts. Repository folders show
  their branch and change count, with independent status for multiple repositories
  inside an opened folder. Click a badge for details; Git status is read-only and
  limited to primary checkouts for now.

### Changed

- Traces uses a compact header and tighter bottom spacing, giving terminals more
  room above the separate status footer. Small trace labels use 10-point text
  for better readability.
- The folder name and path share one titlebar line aligned with the workflow
  strip. A shorter workflow tab row and less space above it give terminals more
  room. The sidebar button retains its standard native proportions, and the
  sidebar uses the native translucent material.
- Workflow creation and terminal split buttons have larger click targets within
  the compact workflow row.

## [0.3.0] - 2026-10-11

### Added

- Create workflow graphs in a native editor that fills the tab. Agent cards have
  system colors and badges that show where work starts and results return. The
  dotted canvas has zoom, Fit, and undo. Fit includes feedback links and event labels.
- Double-click empty canvas space to add an agent. Right-click for canvas tools
  or to duplicate an agent. Click an agent or link to edit its settings beside it;
  press Delete to remove the selected agent and its links. Draw connections from
  either end, between an output and an input. Graph previews support screen readers.
- Connect agents to work in parallel, send pieces while work continues, collect
  results, select a result, or compare completion times. Forward links determine
  which agents start and return results. Feedback links send changes back.
- Set instructions, work rules, and an optional color for each agent. Save optional
  default harness, model, effort, and permission settings. These defaults fill the
  launch form and can be changed before starting.
- Hover over a saved workflow to show its delete button. Confirm deletion in a
  native dialog. Existing runs keep their saved graph.
- Identify debug builds with a DEBUG badge on the app icon.

### Changed

- Twine source, releases, and update checks now use `standing-desks/twine`.
  The website and guides are at `https://standing-desks.github.io/twine/`.

- Homebrew installs now use `standing-desks/tap/twine-ade` (agent development
  environment). Existing installations migrate to the `twine-ade` cask.
- New tabs show separate grids for built-in and user workflows. Create your own
  opens the graph editor in that tab. Commands use New workflow graph and Edit
  Workflow. The designer hides Traces and the restored session bar.
- Store user workflows as versioned TOML files beside the selected config file.
  The default location is `$XDG_CONFIG_HOME/twine/workflows` (or
  `~/.config/twine/workflows`). Debug builds use their own config directory. Share
  files or keep them in version control. Existing saved workflows move from SQLite
  to files; saved runs keep their original definitions. Older definitions with
  duplicate names or names unsuitable for files remain readable in SQLite.
- Name workflow files from the workflow name: lowercase, trim whitespace, and
  replace spaces with underscores. Keep macOS-valid symbols. Empty names use
  `untitled.toml`, `untitled-1.toml`, and so on. Rename the file when the workflow
  name changes and reject duplicate names with a clear message.
- Adversarial and Coordinator ship as TOML agent graphs and use the same editor
  and runtime as user graphs. Coordinator has a planner, two separate workers,
  and a coordinator that waits for both results. Edits to a built-in save as a user
  workflow. Each card represents one agent.
- New saves use file format version 2 and require agent graphs. Older stage
  definitions and version 1 files remain readable. Copying an older Coordinator
  into a graph explains the changes to shared plans, planning and result agents,
  and worker counts.
- Start graph workflows in the agent terminal and enter the task there. Parallel
  start agents receive the same task. After completion or the review limit, enter
  a new task in the same agent conversations. Incoming results identify the agent
  that sent them.
- Restore a Save button in the workflow designer, with File → Save and ⌘S available.

### Fixed

- Opening an idle workflow no longer sends setup instructions as a task or starts
  agent work before the user enters a task.

## [0.2.5] - 2026-10-11

### Changed

- Memories open in file tabs with the app's standard Markdown preview and editor.
  Switch to Source to edit Markdown files directly; rendered memories still hide
  YAML frontmatter, and SQLite records remain read-only. The Memories sidebar
  header is clickable across its full strip.

### Removed

- The brain icon beside the Memories sidebar heading.
- The “Steps in start order” subtitle beneath the Traces heading.

### Fixed

- Keep file and memory viewer controls accessible when switching tabs or using
  narrow windows.
- Keep memory previews current after refresh and preserve completed saves when an
  older memory read finishes.
- Hide the Overview/In Depth toggle when no traces are available.
- Restore File → Save and ⌘S activation as workflow designs and session names become
  valid, without needing to move keyboard focus.

## [0.2.4] - 2026-10-11

### Changed

- Restore workflow and file tabs below the titlebar, the terminal toolbar in Tabs
  and Bento, and the previous terminal split, Traces, and status footer controls.
- Restore the previous trace-filter scrolling and Save-command activation behavior
  along with the folder layout.

### Removed

- The selectable folder path in the status footer and the View menu action for
  showing or hiding Traces introduced in 0.2.3.

## [0.2.3] - 2026-10-10

### Added

- Browse local Codex and Claude Code memories from a bottom-docked sidebar section
  that expands to fill the sidebar. Switch between This workspace, Global, and Other
  workspaces with remembered selections, filters, and scroll positions. Read Markdown
  and SQLite contents with a compact toolbar and source information popover.
  Edit Markdown files with the normal autosave settings, ⌘S, and protection against
  changes on disk.

- Right-click sidebar items to open files in Twine or their default app, open or
  reveal items in Finder, copy paths or names, and expand or collapse folders.
- Inspect recorded LLM calls, public response and reasoning summaries, model
  usage, compaction, retries, and permission events when the harness exposes them.
  Recover missing activity from the exact saved Codex, Claude Code, Pi, and OMP
  conversations, including recorded subagent assignments.
- Open complete recorded inputs and results from the trace inspector, with
  storage usage, per-step pinning, and cleanup controls. Configure the detail
  cache budget and closed-history retention in Settings.
- Capture OpenCode v2 tool, model, and child-session activity through a private
  observer loaded for each launch.

### Changed

- Workflow and file tabs now share the native titlebar, with workflow actions and tab overflow nearby. Bento removes its redundant terminal strip. A slimmer closed Traces capsule and status footer give more room to content while opened Traces keeps its full size; the footer shows a selectable, copyable folder path, and the View menu can show or hide Traces.

- File edits save automatically after a short typing pause, including in background
  tabs. Disable autosave or change its delay in Settings. Keep typing while saving,
  or press ⌘S to save immediately, regardless of the autosave setting. Autosave
  pauses on disk conflicts or save failures so your edits remain protected.
- Save buttons are removed from editors, Settings, the workflow designer, and
  session forms. Use File → Save or ⌘S; session names also accept Return.

### Fixed

- Trace activity stays visible when filtering after scrolling in a compact window.
- File → Save and ⌘S become available when a workflow designer or session form is valid,
  without needing to move keyboard focus.
- HTML and Markdown previews fill their pane at every global zoom level, with
  correctly scaled content and clickable links, including after resizing the window.
- Open Folder remains available after closing the last window and opens a new
  window with the folder picker, so you can continue working without relaunching Twine.
- Keep loaded trace events and older steps visible when live activity refreshes
  the Traces panel. Show saved event logs in In Depth for steps without detailed
  tool activity, including recordings from older versions.
- Preserve queued Pi and OMP trace events during shutdown and keep resumed
  subagent activity attached to its original step.
- Preserve long trace details and activity beyond 10,000 records, combine
  streamed Claude response blocks, and show activity counts and an Inspect
  activity action in Overview.

## [0.2.2] - 2026-10-08

### Added

- Capture trace events and inspect detailed tool activity when using the
  Antigravity agent harness.

## [0.2.1] - 2026-10-07

### Added

- Install Twine with `brew install --cask twineproject/tap/twine-app` and update
  it with `brew upgrade --cask twine-app`. Copy the install command from the website.
- Use **Twine → Check for Updates…** to check for a newer stable release and open
  its release page.
- Load a configuration file from a custom location by setting `TWINE_CONFIG_PATH`
  to its absolute path before launching Twine.

### Changed

- Pasted images are kept with Twine's saved data so their file paths remain
  available after temporary storage is cleared.

### Removed

- Intel Macs are no longer supported. Twine now requires Apple Silicon.

## [0.2.0] - 2026-10-06

### Added

- Open multiple folders in separate windows, each with its own terminals and
  tabs. Your open folders are restored when you relaunch Twine.
- Use Individual mode to follow up with an agent after workflow completion or the
  review limit without starting another workflow cycle.
- Zoom the interface across all windows. Your zoom level is remembered between
  launches and applies to terminals, editors, previews, and dialogs.
- Preview Markdown files, follow local links, and switch to source editing to make
  changes.
- Syntax highlighting for common programming languages and configuration files,
  with automatic language detection and a language menu for each file tab.
- Edit settings in a popup and apply changes immediately across open folders and
  terminals. Invalid settings are explained before saving, and unsaved changes
  are protected when closing the popup.
- Choose from bundled terminal color themes, customize colors, and reuse settings
  through configuration file imports.
- Inspect tool calls and subagent activity in the In Depth trace timeline. Search
  activity, filter failures, preview inputs and outputs, and jump to the related
  terminal output. Activity remains available after relaunch.
- A [user guide](https://aravind-n.github.io/twine/documentation/guide/) covering
  installation, agent workflows, and settings.

### Changed

- Install Twine from a DMG by dragging the app into Applications. The app is now
  signed and notarized for easier installation and first launch.
- Switch between Overview traces for a summary of workflow steps and In Depth
  for a closer look at an agent's activity.
- Terminals resize more smoothly when toggling the sidebar or changing layouts.

### Fixed

- Claude Code conversation history remains available in terminal scrollback.
- Minimap dots and trace navigation more reliably take you to the corresponding
  prompt, including after resizing a terminal.
- Agents receive the correct terminal colors when they start.
- Closing a restored window whose folder is unavailable keeps it closed after
  relaunch.

### Known limitations

- Antigravity and OpenCode v2 do not show tool calls or subagent activity in
  In Depth.

## [0.1.0] - 2026-10-01

Initial release of Twine, a native macOS workspace for coordinating coding agents.

### Known limitations

- The app is ad hoc signed and not notarized. Follow the included install instructions
  to approve the first launch in macOS Privacy & Security settings.

[unreleased]: https://github.com/standing-desks/twine/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/standing-desks/twine/compare/v0.2.5...v0.3.0
[0.2.5]: https://github.com/aravind-n/twine/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/aravind-n/twine/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/aravind-n/twine/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/aravind-n/twine/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/aravind-n/twine/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/aravind-n/twine/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/aravind-n/twine/releases/tag/v0.1.0
