#!/usr/bin/env bash
set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }
version_check() {
    [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'expected MAJOR.MINOR.PATCH'
}
universal() {
    local architectures
    architectures="$(xcrun lipo -archs "$1" | tr ' ' '\n' | sort | xargs)"
    [[ "$architectures" == 'arm64 x86_64' ]] || fail "expected a universal binary: $1 ($architectures)"
}
notes() {
    local version="$1" destination="$2" count
    version_check "$version"
    count="$(awk -v ver="$version" '$1=="##" {h=$2; gsub(/^\[|\]$/, "", h); if(h==ver) n++} END {print n+0}' CHANGELOG.md)"
    [[ "$count" == 1 ]] || fail "expected one CHANGELOG.md section for $version"
    # Same section extraction as ~/projects/vhrn: stop at the next heading or link references.
    awk -v ver="$version" '
        $1=="##" {h=$2; gsub(/^\[|\]$/, "", h); if(h==ver) {cap=1; next} else if(cap) exit}
        cap && /^\[[^][]+\]:/ {exit}
        cap {print}
    ' CHANGELOG.md | sed '/./,$!d' > "$destination"
    awk 'NF && $1 !~ /^#/ {content=1} END {exit !content}' "$destination" || fail "empty changelog section for $version"
}

case "${1:-}" in
    guard)
        tag="${2:?tag required}"
        [[ "$tag" == v* ]] || fail 'expected a vMAJOR.MINOR.PATCH tag'
        version="${tag#v}"
        version_check "$version"
        app_versions="$(awk '
            /buildSettings = \{/ {version=""; app=0}
            /MARKETING_VERSION =/ {version=$3; sub(/;$/, "", version)}
            /PRODUCT_BUNDLE_IDENTIFIER = com.twineproject.Twine;/ {app=1}
            /};/ {if(app) print version; app=0}
        ' macOS/Twine/Twine.xcodeproj/project.pbxproj | sort -u)"
        [[ "$app_versions" == "$version" ]] || fail "tag version $version differs from app version $app_versions"
        core_version="$(awk '
            /^\[workspace.package\]$/ {package=1; next}
            /^\[/ {package=0}
            package && $1=="version" {gsub(/"/, "", $3); print $3}
        ' Cargo.toml)"
        [[ "$core_version" == "$version" ]] || fail "tag version $version differs from core version $core_version"
        git merge-base --is-ancestor HEAD origin/main || fail 'tagged commit is not on main'
        notes "$version" "${3:?notes path required}"
        ;;
    notes)
        notes "${2:?version required}" "${3:?notes path required}"
        ;;
    bundle)
        build="${2:?build directory required}"
        bundle="${3:?bundle directory required}"
        framework=macOS/TwineCorePackage/TwineCore.xcframework/macos-arm64_x86_64
        universal "$build/Twine.app/Contents/MacOS/Twine"
        universal "$framework/libtwine_bridge.a"
        mkdir -p "$bundle"
        build_version="${BUILD_VERSION:-ci-$(git rev-parse HEAD)}"
        [[ "$build_version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail 'invalid build version'
        /usr/libexec/PlistBuddy -c "Set :TwineBuildVersion $build_version" "$build/Twine.app/Contents/Info.plist" 2>/dev/null || \
            /usr/libexec/PlistBuddy -c "Add :TwineBuildVersion string $build_version" "$build/Twine.app/Contents/Info.plist"
        ditto -c -k --sequesterRsrc --keepParent "$build/Twine.app" "$bundle/Twine.app.zip"
        ditto -c -k --sequesterRsrc --keepParent "$build/Twine.app.dSYM" "$bundle/Twine.app.dSYM.zip"
        cp "$framework/libtwine_bridge.a" "$bundle/libtwinecore.a"
        cp "$framework/Headers/twine_bridge.h" "$bundle/twine_bridge.h"
        git rev-parse HEAD > "$bundle/commit.txt"
        ;;
    package|nightly-package)
        version="${2:?version required}"
        bundle="${3:?bundle directory required}"
        output="${4:?output directory required}"
        release_tag="v$version"
        if [[ "$1" == nightly-package ]]; then
            [[ "$version" =~ ^nightly-[0-9]{8}-[0-9a-f]{12}$ ]] || fail 'expected nightly-YYYYMMDD-COMMIT (12 hex characters)'
            [[ "$version" == *-"$(git rev-parse --short=12 HEAD)" ]] || fail 'nightly identifier belongs to another commit'
            release_tag="$version"
        else
            version_check "$version"
        fi
        [[ "$(cat "$bundle/commit.txt")" == "$(git rev-parse HEAD)" ]] || fail 'build artifact belongs to another commit'
        mkdir -p "$output" target
        [[ -z "$(ls -A "$output")" ]] || fail 'output directory must be empty'
        staging="$(mktemp -d "$PWD/target/release-stage.XXXXXX")"
        dmg_mount=""
        cleanup() {
            if [[ -n "$dmg_mount" ]]; then
                hdiutil detach -quiet "$dmg_mount" || hdiutil detach -quiet -force "$dmg_mount" || return
            fi
            rm -rf "$staging"
        }
        trap cleanup EXIT
        folder="$staging/Twine-$version"
        mkdir "$folder"
        ditto -x -k "$bundle/Twine.app.zip" "$folder"
        app="$folder/Twine.app"
        plist="$app/Contents/Info.plist"
        app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
        version_check "$app_version"
        if [[ "$1" == package ]]; then
            [[ "$app_version" == "$version" ]] || fail 'built app version differs from tag'
        fi
        universal "$app/Contents/MacOS/Twine"
        build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
        [[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail 'expected a positive integer build number'
        /usr/libexec/PlistBuddy -c "Set :TwineBuildVersion $version" "$plist"
        # Keep the license with the installed app, without adding an installer-window item.
        mkdir -p "$app/Contents/Resources"
        cp LICENSE "$app/Contents/Resources/LICENSE"
        # Sign nested executable code inside out, then the app. Verify deeply, never sign deeply.
        while IFS= read -r -d '' path; do
            if [[ "$(file -b "$path")" == *Mach-O* ]]; then codesign --force --sign - "$path"; fi
        done < <(find "$app" -type f -print0)
        while IFS= read -r -d '' path; do
            codesign --force --sign - "$path"
        done < <(find "$app" -depth -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' \) -print0)
        codesign --verify --deep --strict "$app"
        [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "$build_number" ]] || fail 'incorrect bundle build number'
        ln -s /Applications "$folder/Applications"
        # Finder artwork stays hidden, leaving only the app and Applications visible.
        cp .github/release/installer-background.tiff "$folder/.background.tiff"
        library="$staging/libtwinecore-$version-macos-universal"
        mkdir -p "$library/include"
        cp "$bundle/libtwinecore.a" "$library/libtwinecore.a"
        cp "$bundle/twine_bridge.h" "$library/include/twine_bridge.h"
        universal "$library/libtwinecore.a"
        test -s "$library/include/twine_bridge.h"
        sed -e "s/@VERSION@/$version/g" -e "s/@RELEASE_TAG@/$release_tag/g" \
            .github/release/library-README.txt > "$library/README.txt"
        cp LICENSE "$library/LICENSE"
        tar -czf "$output/libtwinecore-$version-macos-universal.tar.gz" -C "$staging" "$(basename "$library")"
        symbols="$staging/Twine-$version-symbols"
        mkdir "$symbols"
        ditto -x -k "$bundle/Twine.app.dSYM.zip" "$symbols"
        binary_uuids="$(dwarfdump --uuid "$app/Contents/MacOS/Twine" | awk '{print $2, $3}' | sort)"
        symbol_uuids="$(dwarfdump --uuid "$symbols/Twine.app.dSYM" | awk '{print $2, $3}' | sort)"
        [[ -n "$binary_uuids" && "$binary_uuids" == "$symbol_uuids" ]] || fail 'debug symbols differ from executable'
        tar -czf "$output/Twine-$version-symbols.tar.gz" -C "$staging" "$(basename "$symbols")"
        git archive --format=tar --prefix="twine-$version/" HEAD | gzip -n > "$output/twine-$version-source.tar.gz"
        image="$output/Twine-$version-macos-universal.dmg"
        dmg_python="${TWINE_DMG_PYTHON:-$PWD/target/dmg-tools/bin/python3}"
        [[ -x "$dmg_python" ]] || fail 'run make dmg-tools before packaging'
        writable="$staging/installer.dmg"
        hdiutil create -quiet -volname 'Twine — Drag to Applications' -srcfolder "$folder" -fs HFS+ -format UDRW "$writable"
        dmg_mount="$staging/mounted"
        mkdir "$dmg_mount"
        hdiutil attach -quiet -nobrowse -owners off -mountpoint "$dmg_mount" "$writable"
        "$dmg_python" .github/release/dmg-layout.py "$dmg_mount"
        hdiutil detach -quiet "$dmg_mount"
        dmg_mount=""
        hdiutil convert -quiet "$writable" -format UDZO -o "$image"
        hdiutil verify -quiet "$image"
        (cd "$output"; shasum -a 256 ./*.dmg ./*.tar.gz > SHA256SUMS; shasum -a 256 -c SHA256SUMS)
        ;;
    *) fail 'usage: release.sh guard TAG NOTES | notes VERSION NOTES | bundle BUILD BUNDLE | package VERSION BUNDLE OUTPUT | nightly-package NIGHTLY_ID BUNDLE OUTPUT' ;;
esac
