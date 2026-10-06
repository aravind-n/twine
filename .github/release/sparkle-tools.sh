#!/usr/bin/env bash
set -euo pipefail
# Keep this version and checksum aligned with the app's pinned Sparkle package.
destination="${1:?tools directory required}"
version=2.10.0
checksum=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
if [[ -f "$destination/.version" && "$(cat "$destination/.version")" == "$version-$checksum" ]]; then
    exit 0
fi
mkdir -p "$(dirname "$destination")"
staging="$(mktemp -d "$(dirname "$destination")/sparkle-download.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
curl --fail --location --retry 3 --output "$staging/Sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz"
printf '%s  %s\n' "$checksum" "$staging/Sparkle.tar.xz" | shasum -a 256 -c -
mkdir "$staging/tools"
tar -xJf "$staging/Sparkle.tar.xz" -C "$staging/tools"
test -x "$staging/tools/bin/generate_appcast"
printf '%s\n' "$version-$checksum" > "$staging/tools/.version"
rm -rf "$destination"
mv "$staging/tools" "$destination"
