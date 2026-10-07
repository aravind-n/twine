#!/usr/bin/env bash
set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }
# shellcheck source=.github/release/signing.sh
source "$(dirname "$0")/signing.sh"
version_check() {
    [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'expected MAJOR.MINOR.PATCH'
}
arm64_only() {
    local architectures
    architectures="$(xcrun lipo -archs "$1" | xargs)"
    [[ "$architectures" == arm64 ]] || fail "expected an arm64 binary: $1 ($architectures)"
}
notes() {
    local version="$1" destination="$2" count
    version_check "$version"
    mkdir -p "$(dirname "$destination")"
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
        framework=out/frameworks/release/TwineCore.xcframework/macos-arm64
        arm64_only "$build/Twine.app/Contents/MacOS/Twine"
        arm64_only "$framework/libtwine_bridge.a"
        mkdir -p "$bundle" out/packaging
        staging="$(mktemp -d "$PWD/out/packaging/bundle-stage.XXXXXX")"
        trap 'rm -rf "$staging"' EXIT
        ditto "$build/Twine.app" "$staging/Twine.app"
        build_version="${BUILD_VERSION:-ci-$(git rev-parse HEAD)}"
        [[ "$build_version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail 'invalid build version'
        /usr/libexec/PlistBuddy -c "Set :TwineBuildVersion $build_version" "$staging/Twine.app/Contents/Info.plist" 2>/dev/null || \
            /usr/libexec/PlistBuddy -c "Add :TwineBuildVersion string $build_version" "$staging/Twine.app/Contents/Info.plist"
        ditto -c -k --sequesterRsrc --keepParent "$staging/Twine.app" "$bundle/Twine.app.zip"
        cp "$framework/libtwine_bridge.a" "$bundle/libtwinecore.a"
        cp "$framework/Headers/twine_bridge.h" "$bundle/twine_bridge.h"
        git rev-parse HEAD > "$bundle/commit.txt"
        ;;
    package)
        signing_check
        version="${2:?version required}"
        version_check "$version"
        bundle="${3:?bundle directory required}"
        output="${4:?output directory required}"
        release_tag="v$version"
        [[ "$(cat "$bundle/commit.txt")" == "$(git rev-parse HEAD)" ]] || fail 'build artifact belongs to another commit'
        mkdir -p "$output" out/packaging
        [[ -z "$(ls -A "$output")" ]] || fail 'output directory must be empty'
        staging="$(mktemp -d "$PWD/out/packaging/release-stage.XXXXXX")"
        trap 'rm -rf "$staging"' EXIT
        ditto -x -k "$bundle/Twine.app.zip" "$staging"
        app="$staging/Twine.app"
        plist="$app/Contents/Info.plist"
        app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
        version_check "$app_version"
        [[ "$app_version" == "$version" ]] || fail 'built app version differs from tag'
        arm64_only "$app/Contents/MacOS/Twine"
        build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
        [[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail 'expected a positive integer build number'
        /usr/libexec/PlistBuddy -c "Set :TwineBuildVersion $version" "$plist"
        # Keep the license with the installed app, without adding an installer-window item.
        mkdir -p "$app/Contents/Resources"
        cp LICENSE "$app/Contents/Resources/LICENSE"
        sign_app "$app"
        if [[ "${TWINE_SIGNING_MODE:-developer-id}" == developer-id ]]; then
            ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/Twine.app.zip"
            notarize "$staging/Twine.app.zip" "$app"
        fi
        [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "$build_number" ]] || fail 'incorrect bundle build number'
        library="$staging/libtwinecore-$version-macos-arm64"
        mkdir -p "$library/include"
        cp "$bundle/libtwinecore.a" "$library/libtwinecore.a"
        cp "$bundle/twine_bridge.h" "$library/include/twine_bridge.h"
        arm64_only "$library/libtwinecore.a"
        test -s "$library/include/twine_bridge.h"
        sed -e "s/@VERSION@/$version/g" -e "s/@RELEASE_TAG@/$release_tag/g" \
            .github/release/library-README.txt > "$library/README.txt"
        cp LICENSE "$library/LICENSE"
        tar -czf "$output/libtwinecore-$version-macos-arm64.tar.gz" -C "$staging" "$(basename "$library")"
        git archive --format=tar --prefix="twine-$version/" HEAD | gzip -n > "$output/twine-$version-source.tar.gz"
        image="$output/Twine-$version-macos-arm64.dmg"
        bash "$(dirname "$0")/build-dmg.sh" "$app" "$image"
        if [[ "${TWINE_SIGNING_MODE:-developer-id}" == developer-id ]]; then
            sign_code "$image" container
            verify_developer_id "$image" container
            notarize "$image" "$image"
        fi
        (cd "$output"; shasum -a 256 ./*.dmg ./*.tar.gz > SHA256SUMS; shasum -a 256 -c SHA256SUMS)
        ;;
    *) fail 'usage: bundle-artifact.sh guard TAG NOTES | notes VERSION NOTES | bundle BUILD BUNDLE | package VERSION BUNDLE OUTPUT' ;;
esac
