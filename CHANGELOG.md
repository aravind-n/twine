# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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

- File edits save automatically after a short typing pause, including in background
  tabs. Disable autosave or change its delay in Settings. Keep typing while saving,
  or press ⌘S to save immediately, regardless of the autosave setting. Autosave
  pauses on disk conflicts or save failures so your edits remain protected.
- Save buttons are removed from editors, Settings, the workflow designer, and
  session forms. Use File → Save or ⌘S; session names also accept Return.

### Fixed

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

[unreleased]: https://github.com/aravind-n/twine/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/aravind-n/twine/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/aravind-n/twine/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/aravind-n/twine/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/aravind-n/twine/releases/tag/v0.1.0
