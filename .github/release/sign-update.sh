#!/usr/bin/env bash
set -euo pipefail
image="${1:?update archive required}"
output="${2:?appcast path required}"
version="${3:?version required}"
tag="${4:?tag required}"
[[ -n "${TWINE_UPDATE_PRIVATE_KEY:-}" ]] || { echo 'TWINE_UPDATE_PRIVATE_KEY is required' >&2; exit 1; }
tools="${TWINE_SPARKLE_TOOLS:-$PWD/target/sparkle-tools}"
[[ -x "$tools/bin/generate_appcast" ]] || { echo 'Run make sparkle-tools first' >&2; exit 1; }
staging="$(mktemp -d "$PWD/target/update-signing.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
cp "$image" "$staging/"
args=(--ed-key-file - --maximum-deltas 0 --maximum-versions 0
    --download-url-prefix "https://github.com/aravind-n/twine/releases/download/$tag/"
    -o "$output")
if [[ "$tag" == nightly-* ]]; then args+=(--channel nightly); fi
# The key stays off command lines and disk; only Sparkle reads it through standard input.
printf '%s' "$TWINE_UPDATE_PRIVATE_KEY" | "$tools/bin/generate_appcast" "${args[@]}" "$staging"
python3 .github/release/appcast.py finalize "$output" "$version"
