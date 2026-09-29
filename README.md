# Twine

Twine is an agent workspace for coordinating your agents

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
