# ``Twine``

A native macOS workspace for coordinating coding agents.

## Overview

Twine's SwiftUI and AppKit layer presents folder windows, sessions, workflows,
terminals, files, and traces. Domain state and orchestration live in the Rust
application core. ``CoreClient`` is the Swift entry point for commands and state
published across the C ABI.

This reference includes internal app symbols. It describes the implementation
for contributors; these symbols are not a stable library API.

For installation and usage, see the [Twine user guide](https://aravind-n.github.io/twine/docs/guide/).
For the underlying application core and C ABI, see the
[Rust API reference](https://aravind-n.github.io/twine/docs/rust/twine_core/).

## Topics

### Application and folder windows

- ``TwineApp``
- ``FolderWindowRoot``
- ``FolderView``

### Core communication

- ``CoreClient``
- ``CoreTransport``
- ``CoreWorker``

### Workflows and terminals

- ``WorkflowWorkspace``
- ``WorkflowDesigner``
- ``TerminalController``
