# Rust bridge

`twine-bridge/` is a static library that exposes `twine-core` to the Swift app through a C ABI. It only translates: it converts types, maps errors, and manages buffer ownership. Domain logic and state belong in `twine-core`.

## C ABI rules

- No panic may unwind across an `extern "C"` function. Catch panics at every entry point and return an error instead.
- Null-check pointer arguments and validate lengths. Don't trust data from Swift to be valid UTF-8 or well-formed without checking.
- Every buffer handed to Swift has exactly one release function. Never return pointers to live core objects.
- Terminal bytes use the binary path, never JSON.

## Rust conventions

- **Modules:** Use file-named modules (`foo.rs` next to a `foo/` directory for submodules), never `mod.rs`.
- **Errors:** Define typed errors with `thiserror`. Map core errors to C ABI error codes here; don't add C error codes to core.
- **Logging:** Emit diagnostics with `tracing`, never `println!` or `eprintln!`. The bridge installs the `tracing` subscriber once, when the app initializes the core. Never log secrets, file contents, or terminal output.
- **Formatting and checks:** Run `make fmt-lib` before committing, then `make check-lib`. It runs the rustfmt check, Clippy with warnings denied, and the workspace tests, and must pass.

## Review

After changing Rust code, have the Rust reviewer agent (`rust-reviewer` in Claude Code, `rust_reviewer` in Codex) review the change, and address its findings before committing.
