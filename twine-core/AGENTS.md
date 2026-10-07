# twine-core

Keep `twine-core/` as Twine's UI-independent application library. Put domain state, orchestration, process supervision, PTYs, Git state, and persistence here; expose application commands and events without importing Swift or macOS UI types.

Preserve the distinction between a role in a workflow type and the harness assigned to it.

## Invariants

- **Terminal bytes:** Keep terminal byte streams separate from structured trace events. They travel on the binary path, tagged with a terminal ID and absolute byte offset, never encoded into JSON events.
- **Events:** State events carry a monotonic sequence number. A snapshot plus the events after its sequence never skips or repeats an event.
- **Workflows:** Workflows advance only on an explicit completion signal or a user action, never by parsing terminal text. A process exiting doesn't mean its work succeeded. Loops and parallelism stay within the workflow type's limits.
- **Processes:** Every child process and PTY reader is terminated on shutdown. PTY reads, supervision, and persistence stay off the UI thread. Queues and transcript storage are bounded, and heavy output never starves input.
- **Persistence:** SQLite schema changes go through migrations. After a crash, previously active work is marked interrupted, never complete.
- **Git:** Read only the current branch name. Don't run any other Git operations.

## Rust conventions

- **Modules:** Use file-named modules (`foo.rs` next to a `foo/` directory for submodules), never `mod.rs`.
- **Errors:** Define typed errors with `thiserror`, one error enum per module or subsystem rather than one global enum.
- **Logging:** Emit diagnostics with `tracing` macros and spans, never `println!` or `eprintln!`. Only emit events; never install a subscriber. Never log secrets, file contents, or terminal output.
- **Formatting and checks:** Run `make fmt-lib` before committing, then `make check-lib`. It runs the rustfmt check, Clippy with warnings denied, and the workspace tests, and must pass.

## Review

After changing Rust code, have the Rust reviewer agent (`rust-reviewer` in Claude Code, `rust_reviewer` in Codex) review the change, and address its findings before committing.
