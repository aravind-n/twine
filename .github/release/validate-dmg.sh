#!/usr/bin/env bash
set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }
[[ $# -ge 1 && $# -le 2 && -n "$1" ]] || fail 'usage: validate-dmg.sh DMG [VERSION]'
image="$1"
expected_version="${2:-}"
[[ -f "$image" ]] || fail "DMG not found: $image"
# shellcheck source=.github/release/signing.sh
source "$(dirname "$0")/signing.sh"
case "${TWINE_SIGNING_MODE:-developer-id}" in
    developer-id)
        [[ "${APPLE_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] || fail 'APPLE_TEAM_ID must be a 10-character team ID'
        ;;
    adhoc) ;;
    *) fail 'TWINE_SIGNING_MODE must be developer-id or adhoc' ;;
esac
dmg_python="$PWD/out/packaging/tools/bin/python3"
[[ -x "$dmg_python" ]] || fail 'run make dmg-tools first'

mkdir -p out/packaging
staging="$(mktemp -d "$PWD/out/packaging/dmg-check.XXXXXX")"
mountpoint="$staging/mounted"
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then
        hdiutil detach -quiet "$mountpoint" || hdiutil detach -quiet -force "$mountpoint" || return
    fi
    rm -rf "$staging"
}
trap cleanup EXIT

hdiutil verify -quiet "$image"
hdiutil imageinfo -plist "$image" > "$staging/image.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Format' "$staging/image.plist")" == UDZO ]] || fail 'expected a compressed UDZO image'
mkdir "$mountpoint"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mountpoint" "$image"
mounted=true
visible_items="$(find "$mountpoint" -mindepth 1 -maxdepth 1 ! -name '.*' -exec basename {} \; | sort)"
[[ "$visible_items" == $'Applications\nTwine.app' ]] || fail 'expected only Twine.app and Applications in the installer window'
[[ -L "$mountpoint/Applications" && "$(readlink "$mountpoint/Applications")" == /Applications ]] || fail 'incorrect Applications shortcut'
"$dmg_python" .github/release/dmg-layout.py --verify "$mountpoint"
cmp .github/release/installer-background.tiff "$mountpoint/.background.tiff" || fail 'incorrect installer artwork'
app="$mountpoint/Twine.app"
[[ -d "$app" && ! -L "$app" ]] || fail 'expected an app bundle inside the DMG'
cmp LICENSE "$app/Contents/Resources/LICENSE" || fail 'incorrect app license'
plist="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == com.twineproject.Twine ]] || fail 'incorrect app identifier'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")" == Twine ]] || fail 'incorrect app executable'
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'expected a MAJOR.MINOR.PATCH app version'
[[ -z "$expected_version" || "$version" == "$expected_version" ]] || fail "expected app version $expected_version, found $version"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail 'expected a positive integer build number'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :TwineBuildVersion' "$plist")" == "$version" ]] || fail 'incorrect release build version'
architectures="$(xcrun lipo -archs "$app/Contents/MacOS/Twine" | xargs)"
[[ "$architectures" == arm64 ]] || fail 'expected an arm64 app binary'
verify_developer_id "$app" executable
codesign --display --entitlements - --xml "$app" 2>/dev/null > "$staging/entitlements.plist"
python3 - "$staging/entitlements.plist" macOS/Twine/Twine/Twine.entitlements <<'PY'
import plistlib, sys

with open(sys.argv[1], "rb") as source:
    actual = plistlib.load(source)
with open(sys.argv[2], "rb") as source:
    expected = plistlib.load(source)
if actual != expected:
    raise SystemExit("error: app entitlements differ from the release entitlements")
PY
if [[ "${TWINE_SIGNING_MODE:-developer-id}" == developer-id ]]; then
    verify_developer_id "$image" container
    xcrun stapler validate "$app"
    xcrun stapler validate "$image"
    spctl --assess --type execute --verbose=2 "$app"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$image"
fi
echo "Validated DMG: $image (version $version, build $build_number)"
