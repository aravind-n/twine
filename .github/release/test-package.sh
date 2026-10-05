#!/usr/bin/env bash
set -euo pipefail
export TWINE_SIGNING_MODE=adhoc

# Exercise real macOS disk images, installation, signing, plists, and symbols with a tiny app.
repo="$PWD"
mkdir -p target
fixture="$(mktemp -d "$repo/target/release-package-test.XXXXXX")"
mountpoint="$fixture/mounted image"
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then
        hdiutil detach -quiet "$mountpoint" || hdiutil detach -quiet -force "$mountpoint" || return
    fi
    rm -rf "$fixture"
}
trap cleanup EXIT
bundle="$fixture/bundle"
app="$fixture/Twine.app"
mkdir -p "$app/Contents/MacOS" "$bundle"
cat > "$fixture/app.c" <<'C'
int main(void) { return 0; }
C
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Twine</string>
<key>CFBundleIdentifier</key><string>com.twineproject.Twine</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.3</string>
<key>CFBundleVersion</key><string>42</string>
<key>TwineBuildVersion</key><string>ci-fixture</string>
</dict></plist>
PLIST
build_app() {
    for arch in arm64 x86_64; do
        xcrun clang -arch "$arch" -mmacosx-version-min=26.0 -g -c \
            "$fixture/app.c" -o "$fixture/$1-$arch.o"
        xcrun clang -arch "$arch" -mmacosx-version-min=26.0 \
            "$fixture/$1-$arch.o" -o "$fixture/$1-$arch"
    done
    xcrun lipo -create "$fixture/$1-arm64" "$fixture/$1-x86_64" -output "$2"
}
build_app app "$app/Contents/MacOS/Twine"
xcrun dsymutil "$app/Contents/MacOS/Twine" -o "$fixture/Twine.app.dSYM"
for arch in arm64 x86_64; do
    xcrun ar -rcs "$fixture/$arch.a" "$fixture/app-$arch.o"
done
xcrun lipo -create "$fixture/arm64.a" "$fixture/x86_64.a" -output "$bundle/libtwinecore.a"
printf 'void twine_fixture(void);\n' > "$bundle/twine_bridge.h"
git rev-parse HEAD > "$bundle/commit.txt"
# A reused build must not retain development debugging entitlements when re-signed.
cat > "$fixture/development.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
PLIST
codesign --force --sign - --entitlements "$fixture/development.entitlements" "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$bundle/Twine.app.zip"
ditto -c -k --sequesterRsrc --keepParent "$fixture/Twine.app.dSYM" "$bundle/Twine.app.dSYM.zip"

nightly="nightly-20261005-$(git rev-parse HEAD | cut -c 1-12)"
package() { bash .github/release/release.sh "$@" "$bundle" "$fixture/output"; }
reject() {
    rm -rf "$fixture/output"
    if package "$@" > "$fixture/rejected.log" 2>&1; then
        echo "expected packaging rejection: $*" >&2
        exit 1
    fi
}

reject package "$nightly"
reject package 1.2.4
reject nightly-package 1.2.3
reject nightly-package nightly-20261005-000000000000
printf '%040d\n' 0 > "$bundle/commit.txt"
reject nightly-package "$nightly"
git rev-parse HEAD > "$bundle/commit.txt"

for mode in package nightly-package; do
    rm -rf "$fixture/output" "$fixture/extracted"
    version=1.2.3
    release_tag=v1.2.3
    if [[ "$mode" == nightly-package ]]; then version="$nightly"; release_tag="$nightly"; fi
    package "$mode" "$version"
    (cd "$fixture/output" && shasum -a 256 -c SHA256SUMS)
    [[ "$(find "$fixture/output" -type f | wc -l | tr -d ' ')" == 5 ]]
    image="$fixture/output/Twine-$version-macos-universal.dmg"
    hdiutil verify -quiet "$image"
    hdiutil imageinfo -plist "$image" > "$fixture/image.plist"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :Format' "$fixture/image.plist")" == UDZO ]]
    mkdir -p "$mountpoint" "$fixture/extracted"
    mounted=true
    hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mountpoint" "$image"
    packaged="$mountpoint"
    visible_items="$(find "$packaged" -mindepth 1 -maxdepth 1 ! -name '.*' -exec basename {} \; | sort)"
    [[ "$visible_items" == $'Applications\nTwine.app' ]]
    [[ -L "$packaged/Applications" && "$(readlink "$packaged/Applications")" == /Applications ]]
    "${TWINE_DMG_PYTHON:-$PWD/target/dmg-tools/bin/python3}" .github/release/dmg-layout.py --verify "$packaged"
    cmp .github/release/installer-background.tiff "$packaged/.background.tiff"
    cmp LICENSE "$packaged/Twine.app/Contents/Resources/LICENSE"
    plist="$packaged/Twine.app/Contents/Info.plist"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == 1.2.3 ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == 42 ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :TwineBuildVersion' "$plist")" == "$version" ]]
    codesign --verify --deep --strict "$packaged/Twine.app"
    tar -xzf "$fixture/output/libtwinecore-$version-macos-universal.tar.gz" -C "$fixture/extracted"
    grep -q "releases/tag/$release_tag" "$fixture/extracted/libtwinecore-$version-macos-universal/README.txt"
    # Exercise the Finder copy operation in an isolated Applications directory.
    installed="$fixture/Applications folder/Twine.app"
    ditto "$packaged/Twine.app" "$installed"
    hdiutil detach -quiet "$mountpoint"
    mounted=false
    codesign --verify --deep --strict "$installed"
    codesign --display --entitlements - --xml "$installed" 2>/dev/null > "$fixture/release.entitlements"
    python3 - "$fixture/release.entitlements" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as source:
    entitlements = plistlib.load(source)
assert entitlements["com.apple.security.automation.apple-events"] is True
assert entitlements["com.apple.security.device.camera"] is True
assert not entitlements.get("com.apple.security.get-task-allow", False)
assert not any(key.startswith("com.apple.security.cs.") for key in entitlements)
PY
    cmp LICENSE "$installed/Contents/Resources/LICENSE"
    "$installed/Contents/MacOS/Twine"
    rm -rf "$fixture/Applications folder"
done

# A thin library and mismatched symbols must never reach publication.
cp "$fixture/arm64.a" "$bundle/libtwinecore.a"
reject nightly-package "$nightly"
xcrun lipo -create "$fixture/arm64.a" "$fixture/x86_64.a" -output "$bundle/libtwinecore.a"
printf 'int main(void) { return 1; }\n' > "$fixture/app.c"
build_app other "$fixture/other"
rm -rf "$fixture/Twine.app.dSYM"
xcrun dsymutil "$fixture/other" -o "$fixture/Twine.app.dSYM"
ditto -c -k --sequesterRsrc --keepParent "$fixture/Twine.app.dSYM" "$bundle/Twine.app.dSYM.zip"
reject nightly-package "$nightly"
echo 'Stable and nightly packaging checks passed'
