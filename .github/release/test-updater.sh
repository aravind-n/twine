#!/usr/bin/env bash
set -euo pipefail
# Run only from the root Makefile. Xcode uses the project's default ad hoc signing.
# The script owns app-bundle writes; the sandboxed UI runner only reads them.
mkdir -p target
fixture="$(mktemp -d "$PWD/target/updater-ui-test.XXXXXX")"
server_pid=''
fixture_bundle_id="com.twineproject.Twine.updater-test.$(uuidgen)"
data_root="$HOME/Library/Containers/com.twineproject.TwineUITests.xctrunner/Data/tmp/$fixture_bundle_id"
mkdir -p "$data_root"
cleanup() {
    if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
    while IFS= read -r process_id; do
        kill "$process_id" 2>/dev/null || true
    done < <(pgrep -f "$fixture_bundle_id|$fixture/Applications/Twine.app" || true)
    defaults delete "$fixture_bundle_id" >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Caches/$fixture_bundle_id" "$data_root" "$fixture"
}
trap cleanup EXIT
swift .github/release/update-keys.swift "$fixture/keys"
public_key="$(cat "$fixture/keys/public-key")"
derived_data="${TEST_DERIVED_DATA:-$PWD/target/test-app}"
make build-macos-for-testing TEST_DERIVED_DATA="$derived_data" \
    XCODE_BUILD_ARGS="${XCODE_BUILD_ARGS:-} TWINE_UPDATE_PUBLIC_KEY=$public_key"
mkdir -p "$fixture/Applications" "$fixture/downloads" "$fixture/payload"
app="$derived_data/Build/Products/Debug/Twine.app"
for version in 1 2; do
    destination="$fixture/old-Twine.app"
    if [[ "$version" == 2 ]]; then destination="$fixture/payload/Twine.app"; fi
    ditto "$app" "$destination"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $fixture_bundle_id" "$destination/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$destination/Contents/Info.plist"
    codesign --force --sign - --preserve-metadata=entitlements "$destination"
done
ditto "$fixture/old-Twine.app" "$fixture/Applications/Twine.app"
python3 -u .github/release/updater-fixture.py "$fixture" > "$fixture/server.log" 2>&1 &
server_pid=$!
server_deadline=$((SECONDS + 30))
while [[ ! -s "$fixture/port" ]]; do
    if ! kill -0 "$server_pid" 2>/dev/null || ((SECONDS >= server_deadline)); then
        echo 'The local update server failed to start' >&2
        cat "$fixture/server.log" >&2
        exit 1
    fi
    sleep 0.1
done
port="$(cat "$fixture/port")"
# Copy executable bundles outside the sandboxed runner. Foundation copies made by
# the runner acquire quarantine, preventing these locally signed fixtures launching.
read -r -a tests <<< "${ONLY:-testUpdaterInstallsSignedArchiveAndStopsShell testUpdaterRejectsInvalidSignature testUpdaterSavesAutomaticUpdateChoiceOnQuit testUpdaterAutomaticallyInstallsOnQuit testUpdaterKeepsUnsavedChangesWhenUpdateQuitIsCancelled}"
for test_name in "${tests[@]}"; do
    rm -rf "$fixture/Applications/Twine.app"
    ditto "$fixture/old-Twine.app" "$fixture/Applications/Twine.app"
    test_data="$data_root/$test_name-data"
    config_home="$data_root/$test_name-config"
    mkdir -p "$test_data" "$config_home"
    # Launch Services reapplies this environment after Sparkle relaunches the app.
    python3 - "$fixture" "$test_data" "$config_home" "$port" <<'ENVIRONMENT'
import pathlib, plistlib, sys
fixture = pathlib.Path(sys.argv[1])
data, config, port = sys.argv[2:]
for app in [fixture / "Applications/Twine.app", fixture / "payload/Twine.app"]:
    path = app / "Contents/Info.plist"
    info = plistlib.loads(path.read_bytes())
    info["LSEnvironment"] = {
        "TWINE_DATA_DIRECTORY": data,
        "TWINE_PREFERENCES_SUITE": pathlib.Path(data).name,
        "XDG_CONFIG_HOME": config,
        "TWINE_TEST_UPDATE_FEED_URL": f"http://127.0.0.1:{port}/valid.xml",
        "SHELL": "/bin/sh",
    }
    path.write_bytes(plistlib.dumps(info))
ENVIRONMENT
    codesign --force --sign - --preserve-metadata=entitlements "$fixture/Applications/Twine.app"
    codesign --force --sign - --preserve-metadata=entitlements "$fixture/payload/Twine.app"
    rm -f "$fixture/downloads/Twine.zip" "$fixture/downloads/valid.xml" "$fixture/downloads/invalid.xml"
    ditto -c -k --sequesterRsrc --keepParent "$fixture/payload/Twine.app" "$fixture/downloads/Twine.zip"
    "$TWINE_SPARKLE_TOOLS/bin/generate_appcast" --ed-key-file "$fixture/keys/private-key" \
        --maximum-deltas 0 --maximum-versions 0 --download-url-prefix "http://127.0.0.1:$port/" \
        -o "$fixture/downloads/valid.xml" "$fixture/downloads"
    python3 - "$fixture/downloads" <<'FEED'
import base64, pathlib, sys, xml.etree.ElementTree as ET
path = pathlib.Path(sys.argv[1])
tree = ET.parse(path / "valid.xml")
tree.find("./channel/item/enclosure").set(
    "{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature", base64.b64encode(bytes(64)).decode())
tree.write(path / "invalid.xml", encoding="utf-8", xml_declaration=True)
FEED
    TEST_RUNNER_TWINE_UPDATER_FIXTURE="$fixture" \
    TEST_RUNNER_TWINE_UPDATER_DATA_DIRECTORY="$test_data" \
    TEST_RUNNER_TWINE_UPDATER_CONFIG_HOME="$config_home" \
    TEST_RUNNER_TWINE_UI_TEST_APP_PATH="$fixture/Applications/Twine.app" \
        make ui-test-macos-built UI_TEST_DERIVED_DATA="$derived_data" ONLY="$test_name"
done
