#!/bin/sh
# Package the static library built by the Makefile's framework stage.
set -eu
case "${1:-}" in debug|release) profile=$1 ;; *) echo 'usage: build.sh debug|release' >&2; exit 2 ;; esac
repo=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
root="$repo/out/frameworks"
artifact="$root/$profile/TwineCore.xcframework"
mkdir -p "$root/$profile"
staging=$(mktemp -d "$root/$profile/staging.XXXXXX")
trap 'rm -rf "$staging"' EXIT HUP INT TERM
xcodebuild -create-xcframework -library "$repo/target/aarch64-apple-darwin/$profile/libtwine_bridge.a" \
    -headers "$repo/twine-bridge/include" -output "$staging/TwineCore.xcframework"
for file in libtwine_bridge.a Headers/twine_bridge.h Headers/module.modulemap; do
    [ -f "$staging/TwineCore.xcframework/macos-arm64/$file" ] || {
        echo "error: framework is missing $file" >&2; exit 1;
    }
done
# Keep unchanged framework files intact so Swift's incremental builds stay valid.
if [ ! -d "$artifact" ] || ! diff -qr "$staging/TwineCore.xcframework" "$artifact" >/dev/null; then
    rm -rf "$artifact"
    mv "$staging/TwineCore.xcframework" "$artifact"
fi
sh "$repo/macOS/TwineCorePackage/select.sh" "$profile"
echo "Prepared $profile framework at $artifact"
