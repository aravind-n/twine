Twine @VERSION@

Requirements: macOS 26+, Apple Silicon or Intel.

Install
1. Open Twine-@VERSION@-macos-universal.dmg.
2. Drag Twine.app onto the Applications folder in the disk image window.
3. Eject the Twine disk image and open Twine from Applications.
   The app is ad hoc signed, not Developer ID signed or
   notarized, so macOS may block the first launch.
4. Open System Settings > Privacy & Security. Click "Open Anyway" for
   Twine, then confirm "Open" and authenticate if asked.
   This approves this app; do not disable Gatekeeper globally.

Apple's instructions: https://support.apple.com/en-us/102445
Managed Macs may restrict app approval.

Update: quit Twine and replace Twine.app with the new version. You may
need to approve the updated app again. Your data and settings are retained.

Uninstall: quit Twine and remove Twine.app. Data remains in
~/Library/Application Support/Twine and config in ~/.config/twine.

Verification: download SHA256SUMS alongside this DMG. Run
  shasum -a 256 Twine-@VERSION@-macos-universal.dmg
and compare the DMG's checksum with its entry in SHA256SUMS.

Source, development instructions, and issues: https://github.com/aravind-n/twine
Release notes: https://github.com/aravind-n/twine/releases/tag/@RELEASE_TAG@
