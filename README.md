# Twine

Twine is an agent workspace for coordinating your agents

## Development setup

- Install Xcode 27 and point the developer tools at it: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. The app's Swift package plugins require Xcode rather than the Command Line Tools.
- Install Rust with `rustup`, then install both macOS targets: `rustup target add aarch64-apple-darwin x86_64-apple-darwin`. A universal Release build needs both targets.
- Install Xcode's Metal Toolchain if it is missing: `xcodebuild -downloadComponent MetalToolchain`.
- Open `macOS/Twine/Twine.xcodeproj`, select the `Twine` scheme, and build. Trust the SwiftLint and SwiftTerm build plugins when Xcode prompts. The build compiles and links the Rust library automatically.

From the repository root, the same build works from the command line:

```sh
cargo test --workspace --locked
xcodebuild -project macOS/Twine/Twine.xcodeproj -scheme Twine -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO build
```

Use `-configuration Release -destination 'generic/platform=macOS'` for a universal Release build. No manual copying of the Rust library or C header is needed.
