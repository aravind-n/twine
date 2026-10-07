# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[unreleased]: https://github.com/aravind-n/twine/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/aravind-n/twine/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/aravind-n/twine/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/aravind-n/twine/releases/tag/v0.1.0
