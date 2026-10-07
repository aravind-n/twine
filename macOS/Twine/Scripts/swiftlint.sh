#!/bin/sh
# Run the SwiftLint version pinned in Package.resolved against the macOS app.
set -eu

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
packages_dir="${SWIFT_PACKAGES_DIR:-${project_dir}/../../out/dependencies/SourcePackages}"

swiftlint="${packages_dir}/artifacts/swiftlintplugins/SwiftLintBinary/SwiftLintBinary.artifactbundle/macos/swiftlint"
if [ ! -x "${swiftlint}" ]; then
    echo "error: SwiftLint binary not found at ${swiftlint}; run make deps-debug first" >&2
    exit 1
fi

cd "${project_dir}"
cache_dir="${project_dir}/../../out/dependencies/swiftlint"
mkdir -p "${cache_dir}"
exec "${swiftlint}" lint --quiet --cache-path "${cache_dir}" "$@"
