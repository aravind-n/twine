# Twine

Twine is an new workspace coordination for agents and artifacts

## Files

Show the sidebar to browse the open folder. Expanding a directory loads only its children;
empty directories remain visible. The Rust file watcher checks expanded directories and the
selected file every 500 ms, including changes made by shells and agents.

Select a file to open its read-only text viewer. It supports UTF-8 text up to **2 MiB**, text
selection and copying, and **⌘L** to go to a line. **⌘W** closes the file and returns to the
workflow. Binary files, larger files, deleted paths, symbolic links, and special files show
an explanatory state. Up to 256 directories can be expanded at once.

## Configuration

Twine reads `~/.config/twine/config.toml` at startup and creates a commented default file
on first launch. Settings are parsed and exposed to Swift, but do not change app behavior yet.

```toml
[appearance]
color_scheme = "system" # "system", "light", or "dark"
```

Omitted settings use defaults. Invalid TOML, invalid values, or file errors use the complete
defaults; unknown keys are ignored with a warning. Diagnostics include the file, line, and
key (or `<document>` when a syntax error has no identifiable key). They appear in macOS
Console under the `com.twineproject.Twine` subsystem, without logging config values.

Add settings as fields with defaults in `twine-core/src/config.rs`. The Serde schema drives
parsing, unknown-key warnings, the generated default file, and snapshot serialization;
extend Swift's `BridgeConfig` when a consumer needs the new field.

## Development setup

- Install Xcode 27.0 and point the developer tools at it: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. The SwiftTerm build plugin and SwiftLint both require Xcode rather than the Command Line Tools.
- Install Xcode's Metal Toolchain if it is missing: `xcodebuild -downloadComponent MetalToolchain`.
- To build the library, install the latest stable Rust with `rustup`, then install both macOS targets: `rustup target add aarch64-apple-darwin x86_64-apple-darwin`.
- Build the local binary package once from the repository root: `scripts/build-bridge.sh debug`.
- Open `macOS/Twine/Twine.xcodeproj`, select the `Twine` scheme, and build. Trust the SwiftTerm build plugin when Xcode prompts. Xcode consumes the prebuilt `TwineBridge.xcframework` and does not invoke Cargo.

From the repository root, the same build works from the command line:

```sh
cargo test --workspace --locked
scripts/build-bridge.sh debug
xcodebuild -project macOS/Twine/Twine.xcodeproj -scheme Twine -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO build
```

The generated framework includes its C header and module map and is ignored by Git. App-only work needs neither Cargo nor a Rust rebuild while the matching framework is present. If the framework is missing, package resolution reports the command needed to create it.

For a universal Release build, first run `scripts/build-bridge.sh release`, then use `-configuration Release -destination 'generic/platform=macOS'`. The explicit profile switch replaces the local framework with the requested Debug or Release build.

Lint the Swift code with the SwiftLint version pinned in `Package.resolved`:

```sh
macOS/Twine/Scripts/swiftlint.sh
```
