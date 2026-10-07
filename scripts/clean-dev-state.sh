#!/bin/sh
# Remove the data of the isolated development and test identities. Build outputs stay.
set -eu
repo=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
rm -rf "$repo/out/runtime"
for identity in com.twineproject.Twine.development com.twineproject.TwineTests com.twineproject.TwineUITests com.twineproject.TwineUITests.xctrunner; do
    defaults delete "$identity" >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Caches/$identity" \
        "$HOME/Library/HTTPStorages/$identity" \
        "$HOME/Library/HTTPStorages/$identity.binarycookies" \
        "$HOME/Library/Cookies/$identity.binarycookies" \
        "$HOME/Library/WebKit/$identity" \
        "$HOME/Library/Saved Application State/$identity.savedState" \
        "$HOME/Library/Containers/$identity"
    rm -f "$HOME/Library/Preferences/$identity.plist"
done
for preference in "$HOME/Library/Preferences/com.twineproject.Twine.tests."*.plist; do
    [ -f "$preference" ] || continue
    identity=${preference##*/}
    defaults delete "${identity%.plist}" >/dev/null 2>&1 || true
    rm -f "$preference"
done
