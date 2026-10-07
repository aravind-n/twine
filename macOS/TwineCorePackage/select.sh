#!/bin/sh
# Select a built profile without compiling it (also used after a CI framework cache restore).
set -eu
case "${1:-}" in debug|release) profile=$1 ;; *) echo 'usage: select.sh debug|release' >&2; exit 2 ;; esac
repo=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
root="$repo/out/frameworks"
[ -d "$root/$profile/TwineCore.xcframework" ] || {
    echo "error: run make $profile first" >&2; exit 1;
}
package="$root/TwineCorePackage"
mkdir -p "$package"
if ! cmp -s "$repo/macOS/TwineCorePackage/Package.swift" "$package/Package.swift"; then
    cp "$repo/macOS/TwineCorePackage/Package.swift" "$package/Package.swift"
fi
if [ "$(readlink "$package/TwineCore.xcframework" || true)" != "../$profile/TwineCore.xcframework" ]; then
    rm -f "$package/TwineCore.xcframework"
    ln -s "../$profile/TwineCore.xcframework" "$package/TwineCore.xcframework"
fi
