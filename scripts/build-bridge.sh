#!/bin/sh
set -eu

usage() {
    echo "usage: scripts/build-bridge.sh debug|release" >&2
    exit 2
}

[ "$#" -eq 1 ] || usage

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

repo_root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
package_root="${repo_root}/TwineBridgePackage"
artifact="${package_root}/TwineBridge.xcframework"
target_dir="${repo_root}/target/bridge-xcframework"
deployment_target=26.0

if command -v cargo >/dev/null 2>&1; then
    cargo_bin="$(command -v cargo)"
elif [ -x "${CARGO_HOME:-${HOME}/.cargo}/bin/cargo" ]; then
    cargo_bin="${CARGO_HOME:-${HOME}/.cargo}/bin/cargo"
else
    echo "error: cargo not found; install Rust before building TwineBridge" >&2
    exit 1
fi

for tool in xcodebuild xcrun; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "error: ${tool} not found; install Xcode before building TwineBridge" >&2
        exit 1
    fi
done

for rust_target in aarch64-apple-darwin x86_64-apple-darwin; do
    if command -v rustup >/dev/null 2>&1 && ! rustup target list --installed | grep -qx "${rust_target}"; then
        echo "error: Rust target ${rust_target} is not installed; run 'rustup target add ${rust_target}'" >&2
        exit 1
    fi
done

echo "Building TwineBridge (${configuration}) for arm64 and x86_64"
MACOSX_DEPLOYMENT_TARGET="${deployment_target}" \
CARGO_TARGET_DIR="${target_dir}" \
    "${cargo_bin}" build \
        --manifest-path "${repo_root}/Cargo.toml" \
        --package twine-bridge \
        --locked \
        --target aarch64-apple-darwin \
        --target x86_64-apple-darwin \
        ${cargo_profile}

staging_root="$(mktemp -d "${package_root}/.build-bridge.XXXXXX")"
trap 'rm -rf "${staging_root}"' EXIT HUP INT TERM

universal_library="${staging_root}/libtwine_bridge.a"
xcrun lipo -create \
    "${target_dir}/aarch64-apple-darwin/${profile}/libtwine_bridge.a" \
    "${target_dir}/x86_64-apple-darwin/${profile}/libtwine_bridge.a" \
    -output "${universal_library}"

staged_artifact="${staging_root}/TwineBridge.xcframework"
xcodebuild -create-xcframework \
    -library "${universal_library}" \
    -headers "${repo_root}/twine-bridge/include" \
    -output "${staged_artifact}"

staged_library="${staged_artifact}/macos-arm64_x86_64/libtwine_bridge.a"
for required_file in \
    "${staged_library}" \
    "${staged_artifact}/macos-arm64_x86_64/Headers/twine_bridge.h" \
    "${staged_artifact}/macos-arm64_x86_64/Headers/module.modulemap"
do
    if [ ! -f "${required_file}" ]; then
        echo "error: packaged framework is missing ${required_file}" >&2
        exit 1
    fi
done

architectures="$(xcrun lipo -archs "${staged_library}")"
for required_architecture in arm64 x86_64; do
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
