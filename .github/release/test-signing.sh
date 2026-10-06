#!/usr/bin/env bash
set -euo pipefail

# Exercise the production signing functions and credential lifecycle without Apple credentials or network requests.
mkdir -p target
fixture="$(mktemp -d "$PWD/target/signing-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/temp"
export MOCK_SIGNING_LOG="$fixture/commands.jsonl"
export TWINE_NOTARY_LOG_DIR="$fixture/notary logs"
cat > "$fixture/bin/mock" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
entry = [tool, *args]
# Never record passwords or certificate data, even in this mock.
if tool == "security": entry = [tool, args[0]]
if tool == "xcrun" and args[:2] == ["notarytool", "store-credentials"]: entry = [tool, *args[:2]]
with open(os.environ["MOCK_SIGNING_LOG"], "a") as log:
    log.write(json.dumps(entry) + "\n")
if tool == "codesign":
    if "--display" in args:
        if "--entitlements" in args:
            assert "--xml" in args, "entitlements must be extracted as a plist"
            if os.environ.get("MOCK_DEBUG_ENTITLEMENT"):
                print('<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>')
        else:
            lines = ["Authority=" + os.environ.get("MOCK_AUTHORITY", "Developer ID Application: Test (ABCDEFGHIJ)"),
                     "TeamIdentifier=" + os.environ.get("MOCK_TEAM", "ABCDEFGHIJ")]
            if not os.environ.get("MOCK_NO_TIMESTAMP"): lines.append("Timestamp=Oct 5, 2026")
            if not os.environ.get("MOCK_NO_RUNTIME"): lines.append("CodeDirectory flags=0x10000(runtime)")
            print("\n".join(lines), file=sys.stderr)
    if os.environ.get("MOCK_CODESIGN_FAILURE"): sys.exit(1)
elif tool == "xcrun":
    if args[:2] == ["notarytool", "submit"]:
        if os.environ.get("MOCK_NOTARY_RESPONSE") == "malformed":
            print("service unavailable")
            sys.exit(1)
        if os.environ.get("MOCK_NOTARY_RESPONSE") == "missing-id":
            print('{"status": "Accepted"}')
            sys.exit(0)
        print(json.dumps({"id": "fixture-submission", "status": os.environ.get("MOCK_NOTARY_STATUS", "Accepted")}))
        sys.exit(int(os.environ.get("MOCK_NOTARY_EXIT", "0")))
    elif args[:2] == ["notarytool", "log"]:
        pathlib.Path(args[-1]).write_text('{"issues": []}')
    elif args[:2] == ["stapler", "validate"] and os.environ.get("MOCK_STAPLER_FAILURE"):
        sys.exit(1)
elif tool == "security":
    if args[0] == "create-keychain": pathlib.Path(args[-1]).touch()
    if args[0] == "delete-keychain": pathlib.Path(args[-1]).unlink()
    if args[0] == os.environ.get("MOCK_SECURITY_FAILURE"): sys.exit(1)
elif tool == "file":
    print("Mach-O 64-bit executable")
else:
    raise RuntimeError("unexpected tool: " + tool)
PY
chmod +x "$fixture/bin/mock"
for tool in codesign xcrun security file; do ln -s mock "$fixture/bin/$tool"; done
export PATH="$fixture/bin:$PATH"
fail() { echo "error: $*" >&2; exit 1; }
# shellcheck source=.github/release/signing.sh
source .github/release/signing.sh
reset() {
    : > "$MOCK_SIGNING_LOG"
    export TWINE_SIGNING_MODE=developer-id APPLE_SIGNING_IDENTITY='Developer ID Application: Test (ABCDEFGHIJ)'
    export APPLE_TEAM_ID=ABCDEFGHIJ TWINE_NOTARY_PROFILE=fixture-profile TWINE_SIGNING_KEYCHAIN="$fixture/keychain with spaces"
    unset MOCK_AUTHORITY MOCK_TEAM MOCK_NO_TIMESTAMP MOCK_NO_RUNTIME MOCK_CODESIGN_FAILURE MOCK_DEBUG_ENTITLEMENT
    unset MOCK_NOTARY_STATUS MOCK_NOTARY_EXIT MOCK_NOTARY_RESPONSE MOCK_STAPLER_FAILURE MOCK_SECURITY_FAILURE
}
reject() {
    if bash -c 'set -euo pipefail; fail() { echo "error: $*" >&2; exit 1; }; source .github/release/signing.sh; "$@"' \
        _ "$@" > "$fixture/rejected.log" 2>&1; then fail "expected rejection: $*"; fi
}
reset
signing_check
APPLE_SIGNING_IDENTITY=- reject signing_check
APPLE_TEAM_ID=invalid reject signing_check
TWINE_NOTARY_PROFILE='' reject signing_check
TWINE_SIGNING_MODE=invalid reject signing_check

app="$fixture/App with spaces.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks/Nested.framework"
touch "$app/Contents/MacOS/Twine" "$app/Contents/Frameworks/Nested.framework/Nested"
sign_app "$app"
sign_code "$fixture/image.dmg" container
python3 - "$app" <<'PY'
import json, os, pathlib, sys
commands = [json.loads(line) for line in pathlib.Path(os.environ["MOCK_SIGNING_LOG"]).read_text().splitlines()]
signs = [args for args in commands if args[0] == "codesign" and "--sign" in args]
assert len(signs) == 5
assert signs[-2][-1] == sys.argv[1]
assert signs[-2][signs[-2].index("--entitlements") + 1] == "macOS/Twine/Twine/Twine.entitlements"
assert signs[-3][-1].endswith("Nested.framework")
assert all("--entitlements" not in args for args in signs if args[-1] != sys.argv[1])
for args in signs:
    assert "--deep" not in args
    assert args[args.index("--sign") + 1] == os.environ["APPLE_SIGNING_IDENTITY"]
    assert "--timestamp" in args and "--keychain" in args
    if args[-1].endswith(".dmg"): assert "--options" not in args
    else: assert args.index("--sign") < args.index("--options") and args[args.index("--options") + 1] == "runtime"
PY
MOCK_AUTHORITY='Apple Development: Test' reject verify_developer_id "$app" executable
MOCK_TEAM=KLMNOPQRST reject verify_developer_id "$app" executable
MOCK_NO_TIMESTAMP=1 reject verify_developer_id "$app" executable
MOCK_NO_RUNTIME=1 reject verify_developer_id "$app" executable
MOCK_DEBUG_ENTITLEMENT=1 reject verify_developer_id "$app" executable
MOCK_CODESIGN_FAILURE=1 reject sign_app "$app"

reset
notarize "$fixture/App.zip" "$app"
python3 - <<'PY'
import json, os, pathlib
commands = [json.loads(line) for line in pathlib.Path(os.environ["MOCK_SIGNING_LOG"]).read_text().splitlines()]
assert [args[1:3] for args in commands] == [["notarytool", "submit"], ["notarytool", "log"], ["stapler", "staple"], ["stapler", "validate"]]
assert "--wait" in commands[0] and "--timeout" in commands[0] and "--keychain" in commands[0]
assert len(list(pathlib.Path(os.environ["TWINE_NOTARY_LOG_DIR"]).glob("*.json"))) == 2
PY
for status in Invalid 'In Progress'; do
    reset
    MOCK_NOTARY_STATUS="$status" reject notarize "$fixture/App.zip" "$app"
    if grep -Fq '"stapler"' "$MOCK_SIGNING_LOG"; then fail 'rejected submission was stapled'; fi
done
for response in malformed missing-id; do
    reset
    MOCK_NOTARY_RESPONSE="$response" reject notarize "$fixture/App.zip" "$app"
    if grep -Fq '"stapler"' "$MOCK_SIGNING_LOG"; then fail 'invalid response was stapled'; fi
done
reset
MOCK_NOTARY_EXIT=1 reject notarize "$fixture/App.zip" "$app"
MOCK_STAPLER_FAILURE=1 reject notarize "$fixture/App.zip" "$app"

reset
export TWINE_SIGNING_MODE=adhoc
unset APPLE_SIGNING_IDENTITY APPLE_TEAM_ID TWINE_NOTARY_PROFILE TWINE_SIGNING_KEYCHAIN
signing_check
sign_code "$app" executable
verify_developer_id "$app" executable
notarize "$fixture/App.zip" "$app"
python3 - <<'PY'
import json, os, pathlib
commands = [json.loads(line) for line in pathlib.Path(os.environ["MOCK_SIGNING_LOG"]).read_text().splitlines()]
assert commands == [["codesign", "--force", "--sign", "-", commands[0][-1]], ["codesign", "--verify", "--deep", "--strict", commands[0][-1]]]
PY

reset
export RUNNER_TEMP="$fixture/temp"
export APPLE_CERTIFICATE_P12_BASE64=Zml4dHVyZQ== APPLE_CERTIFICATE_PASSWORD=fixture-password
export APPLE_ID=fixture@example.test APPLE_NOTARIZATION_PASSWORD=fixture-app-password
bash .github/release/with-signing.sh python3 - <<'PY'
import os, pathlib
assert pathlib.Path(os.environ["TWINE_SIGNING_KEYCHAIN"]).exists()
assert os.environ["TWINE_SIGNING_MODE"] == "developer-id"
assert os.environ["TWINE_NOTARY_PROFILE"] == "twine-release"
assert all(key not in os.environ for key in ["APPLE_CERTIFICATE_P12_BASE64", "APPLE_CERTIFICATE_PASSWORD", "APPLE_NOTARIZATION_PASSWORD", "APPLE_ID"])
PY
[[ -z "$(ls -A "$RUNNER_TEMP")" ]] || fail 'credentials survived successful command'
if bash .github/release/with-signing.sh bash -c 'exit 23'; then fail 'failed command succeeded'; else [[ $? == 23 ]]; fi
[[ -z "$(ls -A "$RUNNER_TEMP")" ]] || fail 'credentials survived failed command'
if bash .github/release/with-signing.sh bash -c 'kill -TERM "$PPID"'; then fail 'terminated command succeeded'; else [[ $? == 143 ]]; fi
[[ -z "$(ls -A "$RUNNER_TEMP")" ]] || fail 'credentials survived termination'
MOCK_SECURITY_FAILURE=import reject bash .github/release/with-signing.sh true
[[ -z "$(ls -A "$RUNNER_TEMP")" ]] || fail 'credentials survived failed setup'
reset
APPLE_CERTIFICATE_P12_BASE64='' reject bash .github/release/with-signing.sh true
[[ ! -s "$MOCK_SIGNING_LOG" ]] || fail 'missing secret allowed credential setup'
echo 'Signing, notarization, and credential cleanup checks passed'
