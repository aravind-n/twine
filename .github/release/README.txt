Twine @VERSION@

Requirements: macOS 26+, Apple Silicon or Intel. Rust and Xcode are not
needed to run the prebuilt app. Install and authenticate any agent harness
(Claude Code, Codex, or pi) separately.

Install
1. Extract the ZIP and move Twine.app to Applications.
2. Open Twine.app. The app is ad hoc signed, not Developer ID signed or
   notarized, so macOS may block the first launch.
3. Open System Settings > Privacy & Security. Click "Open Anyway" for
   Twine, then confirm "Open" and authenticate if asked.
   This approves this app; do not disable Gatekeeper globally.

Apple's instructions: https://support.apple.com/en-us/102445
Managed Macs may restrict app approval.

Update: quit Twine and replace Twine.app with the new version. You may
need to approve the updated app again. Your data and settings are retained.

Uninstall: quit Twine and remove Twine.app. Data remains in
~/Library/Application Support/Twine and config in ~/.config/twine.

Verification: download SHA256SUMS alongside this ZIP. Run
  shasum -a 256 Twine-@VERSION@-macos-universal.zip
and compare the ZIP's checksum with its entry in SHA256SUMS.

Source, development instructions, and issues: https://github.com/aravind-n/twine
Release notes: https://github.com/aravind-n/twine/releases/tag/v@VERSION@
