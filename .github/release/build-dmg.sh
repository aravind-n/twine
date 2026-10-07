#!/usr/bin/env bash
set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }
[[ $# == 2 && -n "$1" && -n "$2" ]] || fail 'usage: build-dmg.sh APP DMG'
app="$1"
image="$2"
[[ -d "$app" ]] || fail "app not found: $app"
[[ "$image" == *.dmg ]] || fail 'output must have a .dmg extension'
[[ ! -e "$image" && ! -L "$image" ]] || fail "output already exists: $image"
dmg_python="$PWD/out/packaging/tools/bin/python3"
[[ -x "$dmg_python" ]] || fail 'run make dmg-tools first'

mkdir -p out/packaging "$(dirname "$image")"
staging="$(mktemp -d "$PWD/out/packaging/dmg-build.XXXXXX")"
mountpoint="$staging/mounted"
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then
        hdiutil detach -quiet "$mountpoint" || hdiutil detach -quiet -force "$mountpoint" || return
    fi
    rm -rf "$staging"
}
trap cleanup EXIT

folder="$staging/contents"
mkdir "$folder"
ditto "$app" "$folder/Twine.app"
ln -s /Applications "$folder/Applications"
cp .github/release/installer-background.tiff "$folder/.background.tiff"
writable="$staging/installer.dmg"
hdiutil create -quiet -volname 'Twine — Drag to Applications' -srcfolder "$folder" -fs HFS+ -format UDRW "$writable"
mkdir "$mountpoint"
hdiutil attach -quiet -nobrowse -owners off -mountpoint "$mountpoint" "$writable"
mounted=true
"$dmg_python" .github/release/dmg-layout.py "$mountpoint"
hdiutil detach -quiet "$mountpoint"
mounted=false
hdiutil convert -quiet "$writable" -format UDZO -o "$image"
echo "Created DMG: $image"
