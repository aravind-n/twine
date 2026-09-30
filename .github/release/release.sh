#!/usr/bin/env bash
# Package the existing macOS build; no Rust or Swift application behavior lives here.
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
    package)
        version="${2:?version required}"
        bundle="${3:?bundle directory required}"
        output="${4:?output directory required}"
        version_check "$version"
        [[ "$(cat "$bundle/commit.txt")" == "$(git rev-parse HEAD)" ]] || fail 'build artifact belongs to another commit'
        mkdir -p "$output" target
        [[ -z "$(ls -A "$output")" ]] || fail 'output directory must be empty'
        staging="$(mktemp -d "$PWD/target/release-stage.XXXXXX")"
        trap 'rm -rf "$staging"' EXIT
        folder="$staging/Twine-$version"
        mkdir "$folder"
        ditto -x -k "$bundle/Twine.app.zip" "$folder"
        app="$folder/Twine.app"
        plist="$app/Contents/Info.plist"
        [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$version" ]] || fail 'built app version differs from tag'
        universal "$app/Contents/MacOS/Twine"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$plist"
        /usr/libexec/PlistBuddy -c "Set :TwineBuildVersion $version" "$plist"
        # Sign nested executable code inside out, then the app. Verify deeply, never sign deeply.
        while IFS= read -r -d '' path; do
            if [[ "$(file -b "$path")" == *Mach-O* ]]; then codesign --force --sign - "$path"; fi
        done < <(find "$app" -type f -print0)
        while IFS= read -r -d '' path; do
            codesign --force --sign - "$path"
        done < <(find "$app" -depth -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' \) -print0)
        codesign --verify --deep --strict "$app"
        [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "$version" ]] || fail 'incorrect bundle version'
        sed "s/@VERSION@/$version/g" .github/release/README.txt > "$folder/README.txt"
        cp LICENSE "$folder/LICENSE"
        ditto -c -k --sequesterRsrc --keepParent "$folder" "$output/Twine-$version-macos-universal.zip"
        library="$staging/libtwinecore-$version-macos-universal"
        mkdir -p "$library/include"
        cp "$bundle/libtwinecore.a" "$library/libtwinecore.a"
        cp "$bundle/twine_bridge.h" "$library/include/twine_bridge.h"
        universal "$library/libtwinecore.a"
        test -s "$library/include/twine_bridge.h"
        sed "s/@VERSION@/$version/g" .github/release/library-README.txt > "$library/README.txt"
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
        (cd "$output"; shasum -a 256 ./*.zip ./*.tar.gz > SHA256SUMS; shasum -a 256 -c SHA256SUMS)
        ;;
    *) fail 'usage: release.sh guard TAG NOTES | notes VERSION NOTES | bundle BUILD BUNDLE | package VERSION BUNDLE OUTPUT' ;;
esac
