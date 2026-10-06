#!/bin/sh
set -eu

usage() {
    echo "usage: macOS/TwineCorePackage/build.sh debug|release [universal|arm64]" >&2
    exit 2
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    usage
fi

case "$1" in
    debug)
        configuration=Debug
        profile=debug
        cargo_profile=
        ;;
    release)
        configuration=Release
        profile=release
        cargo_profile=--release
        ;;
    *)
        usage
        ;;
esac

architecture="${2:-universal}"
case "$architecture" in
    universal)
        rust_targets='aarch64-apple-darwin x86_64-apple-darwin'
        required_architectures='arm64 x86_64'
        framework_slice=macos-arm64_x86_64
        ;;
    arm64)
        # Release bundles always contain both architectures.
        [ "$profile" = debug ] || usage
        rust_targets=aarch64-apple-darwin
        required_architectures=arm64
        framework_slice=macos-arm64
        ;;
    *) usage ;;
esac

repo_root="$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)"
package_root="${repo_root}/macOS/TwineCorePackage"
artifact="${package_root}/TwineCore.xcframework"
target_dir="${repo_root}/target/core-xcframework"
deployment_target=26.0

if command -v cargo >/dev/null 2>&1; then
    cargo_bin="$(command -v cargo)"
elif [ -x "${CARGO_HOME:-${HOME}/.cargo}/bin/cargo" ]; then
    cargo_bin="${CARGO_HOME:-${HOME}/.cargo}/bin/cargo"
else
    echo "error: cargo not found; install Rust before building TwineCore" >&2
    exit 1
fi

for tool in xcodebuild xcrun; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "error: ${tool} not found; install Xcode before building TwineCore" >&2
        exit 1
    fi
done

set --
for rust_target in $rust_targets; do
    if command -v rustup >/dev/null 2>&1 && ! rustup target list --installed | grep -qx "${rust_target}"; then
        echo "error: Rust target ${rust_target} is not installed; run 'rustup target add ${rust_target}'" >&2
        exit 1
    fi
    set -- "$@" --target "$rust_target"
done

echo "Building TwineCore (${configuration}) for $required_architectures"
MACOSX_DEPLOYMENT_TARGET="${deployment_target}" \
CARGO_TARGET_DIR="${target_dir}" \
    "${cargo_bin}" build \
        --manifest-path "${repo_root}/Cargo.toml" \
        --package twine-bridge \
        --locked \
        "$@" \
        ${cargo_profile}

staging_root="$(mktemp -d "${package_root}/.build-core.XXXXXX")"
trap 'rm -rf "${staging_root}"' EXIT HUP INT TERM

packaged_library="${staging_root}/libtwine_bridge.a"
if [ "$architecture" = universal ]; then
    xcrun lipo -create \
        "${target_dir}/aarch64-apple-darwin/${profile}/libtwine_bridge.a" \
        "${target_dir}/x86_64-apple-darwin/${profile}/libtwine_bridge.a" \
        -output "${packaged_library}"
else
    cp "${target_dir}/aarch64-apple-darwin/${profile}/libtwine_bridge.a" "${packaged_library}"
fi

staged_artifact="${staging_root}/TwineCore.xcframework"
xcodebuild -create-xcframework \
    -library "${packaged_library}" \
    -headers "${repo_root}/twine-bridge/include" \
    -output "${staged_artifact}"

staged_library="${staged_artifact}/${framework_slice}/libtwine_bridge.a"
for required_file in \
    "${staged_library}" \
    "${staged_artifact}/${framework_slice}/Headers/twine_bridge.h" \
    "${staged_artifact}/${framework_slice}/Headers/module.modulemap"
do
    if [ ! -f "${required_file}" ]; then
        echo "error: packaged framework is missing ${required_file}" >&2
        exit 1
    fi
done

architectures="$(xcrun lipo -archs "${staged_library}")"
for required_architecture in $required_architectures; do
    case " ${architectures} " in
        *" ${required_architecture} "*) ;;
        *)
            echo "error: packaged framework is missing ${required_architecture}; found: ${architectures}" >&2
            exit 1
            ;;
    esac
done

rm -rf "${artifact}"
mv "${staged_artifact}" "${artifact}"

echo "Built ${configuration} framework at ${artifact}"
