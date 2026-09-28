#!/bin/sh
set -eu

repo_root="$(cd "${SRCROOT}/../.." && pwd)"
export CARGO_TARGET_DIR="${DERIVED_FILE_DIR}/cargo"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:?Xcode must set the macOS deployment target}"

if command -v cargo >/dev/null 2>&1; then
    cargo_bin="$(command -v cargo)"
elif [ -x "${CARGO_HOME:-${HOME}/.cargo}/bin/cargo" ]; then
    cargo_bin="${CARGO_HOME:-${HOME}/.cargo}/bin/cargo"
elif [ -x /opt/homebrew/bin/cargo ]; then
    cargo_bin=/opt/homebrew/bin/cargo
elif [ -x /usr/local/bin/cargo ]; then
    cargo_bin=/usr/local/bin/cargo
else
    echo "error: cargo not found; install Rust before building Twine" >&2
    exit 1
fi

case "${CONFIGURATION}" in
    Debug)
        profile=debug
        ;;
    Release)
        profile=release
        ;;
    *)
        echo "error: unsupported Xcode configuration: ${CONFIGURATION}" >&2
        exit 1
        ;;
esac

mkdir -p "${DERIVED_FILE_DIR}"
set --
for arch in ${ARCHS:?Xcode must set target architectures}; do
    case "${arch}" in
        arm64)
            rust_target=aarch64-apple-darwin
            ;;
        x86_64)
            rust_target=x86_64-apple-darwin
            ;;
        *)
            echo "error: unsupported macOS architecture: ${arch}" >&2
            exit 1
            ;;
    esac

    if [ "${profile}" = release ]; then
        "${cargo_bin}" build --manifest-path "${repo_root}/Cargo.toml" --package twine-bridge --locked --release --target "${rust_target}"
    else
        "${cargo_bin}" build --manifest-path "${repo_root}/Cargo.toml" --package twine-bridge --locked --target "${rust_target}"
    fi
    set -- "$@" "${CARGO_TARGET_DIR}/${rust_target}/${profile}/libtwine_bridge.a"
done

output="${DERIVED_FILE_DIR}/libtwine_bridge.a"
if [ "$#" -eq 1 ]; then
    cp "$1" "${output}"
else
    xcrun lipo -create "$@" -output "${output}"
fi
