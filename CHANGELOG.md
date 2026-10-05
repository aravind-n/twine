# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Distribute the macOS app in a DMG with an Applications shortcut for drag-and-drop
  installation, and select that installer from the website's download buttons.

## [0.1.0] - 2026-10-01

Initial release of Twine, a native macOS workspace for coordinating coding agents.

### Known limitations

- The app is ad hoc signed and not notarized. Follow the included install instructions
  to approve the first launch in macOS Privacy & Security settings.
- Agent harnesses must be installed and authenticated separately. Tracing and
  conversation resumption depend on the harness and its version.

[unreleased]: https://github.com/aravind-n/twine/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/aravind-n/twine/releases/tag/v0.1.0
