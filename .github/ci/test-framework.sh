#!/usr/bin/env bash
set -euo pipefail

# Exercise packaging and rejection paths without Rust compilation or an Apple SDK.
repo="$PWD"
mkdir -p target
fixture="$(mktemp -d "$repo/target/framework-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/macOS/TwineCorePackage" "$fixture/twine-bridge/include" "$fixture/bin"
cp macOS/TwineCorePackage/build.sh "$fixture/macOS/TwineCorePackage/"
cp twine-bridge/include/* "$fixture/twine-bridge/include/"
export TWINE_TEST_TOOL_LOG="$fixture/tools.log"

cat > "$fixture/bin/tool" <<'TOOL'
#!/usr/bin/env bash
set -euo pipefail
case "${0##*/}" in
    rustup)
        printf '%s\n' aarch64-apple-darwin
        if [[ "${TWINE_TEST_MISSING_TARGET:-}" != x86_64-apple-darwin ]]; then
            printf '%s\n' x86_64-apple-darwin
        fi
        ;;
    cargo)
        printf '%s\n' "$*" >> "$TWINE_TEST_TOOL_LOG"
        profile=debug
        for argument in "$@"; do
            if [[ "$argument" == --release ]]; then profile=release; fi
        done
        previous=
        for argument in "$@"; do
            if [[ "$previous" == --target ]]; then
                directory="$CARGO_TARGET_DIR/$argument/$profile"
                mkdir -p "$directory"
                case "$argument" in
                    aarch64-apple-darwin) echo arm64 > "$directory/libtwine_bridge.a" ;;
                    x86_64-apple-darwin) echo x86_64 > "$directory/libtwine_bridge.a" ;;
                    *) exit 1 ;;
                esac
            fi
            previous="$argument"
        done
        ;;
    xcrun)
        [[ "$1" == lipo ]]
        shift
        if [[ "$1" == -archs ]]; then
            tr '\n' ' ' < "$2"
        else
            [[ "$1" == -create ]]
            cat "$2" "$3" > "$5"
        fi
        ;;
    xcodebuild)
        [[ "$1" == -create-xcframework ]]
        library="$3"
        headers="$5"
        output="$7"
        slice=macos-arm64
        if grep -q x86_64 "$library"; then slice=macos-arm64_x86_64; fi
        mkdir -p "$output/$slice/Headers"
        cp "$library" "$output/$slice/libtwine_bridge.a"
        cp "$headers/"* "$output/$slice/Headers/"
        if [[ "${TWINE_TEST_BREAK_HEADER:-}" == 1 ]]; then
            rm "$output/$slice/Headers/twine_bridge.h"
        fi
        ;;
esac
TOOL
chmod +x "$fixture/bin/tool"
for tool in rustup cargo xcrun xcodebuild; do
    ln -s tool "$fixture/bin/$tool"
done
export PATH="$fixture/bin:$PATH"
build="$fixture/macOS/TwineCorePackage/build.sh"
artifact="$fixture/macOS/TwineCorePackage/TwineCore.xcframework"

bash "$build" debug arm64 >/dev/null
[[ "$(cat "$artifact/macos-arm64/libtwine_bridge.a")" == arm64 ]]
[[ ! -e "$artifact/macos-arm64_x86_64" ]]
[[ "$(cat "$TWINE_TEST_TOOL_LOG")" != *x86_64-apple-darwin* ]]

bash "$build" debug >/dev/null
[[ "$(tr '\n' ' ' < "$artifact/macos-arm64_x86_64/libtwine_bridge.a")" == 'arm64 x86_64 ' ]]
bash "$build" release >/dev/null
[[ "$(tail -n 1 "$TWINE_TEST_TOOL_LOG")" == *--release* ]]
[[ -f "$artifact/macos-arm64_x86_64/Headers/twine_bridge.h" ]]
touch "$artifact/preserve"

reject() {
    if bash "$build" "$@" >/dev/null 2>&1; then
        echo "Framework build unexpectedly accepted: $*" >&2
        exit 1
    fi
    [[ -f "$artifact/preserve" ]]
}
reject release arm64
reject debug invalid
reject
reject debug arm64 extra
export TWINE_TEST_MISSING_TARGET=x86_64-apple-darwin
reject debug
unset TWINE_TEST_MISSING_TARGET
export TWINE_TEST_BREAK_HEADER=1
reject debug arm64
echo 'Framework packaging tests passed'
