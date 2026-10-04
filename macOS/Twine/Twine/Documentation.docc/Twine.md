# ``Twine``

A native macOS workspace for coordinating coding agents.

## Overview

Twine's macOS front end presents folder windows, sessions, workflows,
terminals, files, and traces. Application state and orchestration live in the
`twine-core` library. ``CoreClient`` is the Swift entry point for commands and state
published across the C ABI.

This reference includes internal app symbols. It describes the implementation
for contributors; these symbols are not a stable library API.

For installation and usage, see the [Twine user guide](https://aravind-n.github.io/twine/documentation/guide/).
For the reusable application library and its C interface, see the
[twine-core reference](https://aravind-n.github.io/twine/documentation/rust/).

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
