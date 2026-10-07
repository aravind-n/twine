#!/usr/bin/env bash
# Sourced by the release bundler, DMG validator, and signing tests.

signing_check() {
    case "${TWINE_SIGNING_MODE:-developer-id}" in
        developer-id)
            [[ -n "${APPLE_SIGNING_IDENTITY:-}" && "$APPLE_SIGNING_IDENTITY" != - ]] \
                || fail 'APPLE_SIGNING_IDENTITY must name a Developer ID Application identity'
            [[ "${APPLE_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] || fail 'APPLE_TEAM_ID must be a 10-character team ID'
            [[ -n "${TWINE_NOTARY_PROFILE:-}" ]] || fail 'TWINE_NOTARY_PROFILE is required for notarization'
            ;;
        adhoc) ;;
        *) fail 'TWINE_SIGNING_MODE must be developer-id or adhoc' ;;
    esac
}

sign_code() {
    local path="$1" kind="$2" entitlements="${3:-}"
    local args=(--force --sign -)
    if [[ "${TWINE_SIGNING_MODE:-developer-id}" == developer-id ]]; then
        args=(--force --sign "$APPLE_SIGNING_IDENTITY" --timestamp)
        if [[ "$kind" == executable ]]; then args+=(--options runtime); fi
        if [[ -n "${TWINE_SIGNING_KEYCHAIN:-}" ]]; then args+=(--keychain "$TWINE_SIGNING_KEYCHAIN"); fi
    fi
    if [[ -n "$entitlements" ]]; then
        if [[ "${TWINE_SIGNING_MODE:-developer-id}" == adhoc ]]; then args+=(--options runtime); fi
        args+=(--entitlements "$entitlements")
    fi
    codesign "${args[@]}" "$path" || fail "could not sign: $path"
}

verify_developer_id() {
    local path="$1" kind="$2" details
    codesign --verify --deep --strict "$path" || fail "invalid signature: $path"
    [[ "${TWINE_SIGNING_MODE:-developer-id}" == developer-id ]] || return 0
    details="$(codesign --display --verbose=4 "$path" 2>&1)" || fail "could not inspect signature: $path"
    grep -q '^Authority=Developer ID Application:' <<< "$details" || fail "missing Developer ID Application signature: $path"
    grep -qx "TeamIdentifier=$APPLE_TEAM_ID" <<< "$details" || fail "incorrect signing team: $path"
    grep -q '^Timestamp=' <<< "$details" || fail "missing secure timestamp: $path"
    if [[ "$kind" == executable ]]; then
        grep -q 'flags=.*(.*runtime.*)' <<< "$details" || fail "missing hardened runtime: $path"
        local entitlements
        entitlements="$(codesign --display --entitlements - --xml "$path" 2>/dev/null)" || fail "could not inspect entitlements: $path"
        if [[ -n "$entitlements" ]]; then
            local debug_allowed
            debug_allowed="$(python3 -c 'import plistlib, sys; print(plistlib.loads(sys.stdin.buffer.read()).get("com.apple.security.get-task-allow", False))' <<< "$entitlements")" \
                || fail "invalid entitlements: $path"
            [[ "$debug_allowed" != True && "$debug_allowed" != true && "$debug_allowed" != YES && "$debug_allowed" != 1 ]] \
                || fail "release signature allows debugging: $path"
        fi
    fi
}

sign_app() {
    local app="$1" path
    # Sign nested executable code inside out, then the app. Never sign with --deep.
    while IFS= read -r -d '' path; do
        if [[ "$(file -b "$path")" == *Mach-O* ]]; then
            sign_code "$path" executable
            verify_developer_id "$path" executable
        fi
    done < <(find "$app" -type f -print0)
    while IFS= read -r -d '' path; do
        if [[ "$path" == "$app" ]]; then
            sign_code "$path" executable macOS/Twine/Twine/Twine.entitlements
        else
            sign_code "$path" executable
        fi
        verify_developer_id "$path" executable
    done < <(find "$app" -depth -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' \) -print0)
}

notarize() {
    local archive="$1" staple_path="$2" status=0 submission_id result
    [[ "${TWINE_SIGNING_MODE:-developer-id}" == developer-id ]] || return 0
    local args=(--keychain-profile "$TWINE_NOTARY_PROFILE")
    if [[ -n "${TWINE_SIGNING_KEYCHAIN:-}" ]]; then args+=(--keychain "$TWINE_SIGNING_KEYCHAIN"); fi
    local log_dir="${TWINE_NOTARY_LOG_DIR:-$PWD/out/packaging/notarization}"
    mkdir -p "$log_dir"
    result="$log_dir/$(basename "$archive").submission.json"
    xcrun notarytool submit "$archive" "${args[@]}" --wait --timeout 45m --output-format json > "$result" || status=$?
    submission_id="$(jq -r '.id // empty' "$result")" || fail "invalid notarization response: $result"
    [[ -n "$submission_id" ]] || fail "no notarization submission ID: $result"
    echo "Notarization submission: $submission_id ($archive)"
    if [[ "$(jq -r '.status // empty' "$result")" == Accepted && "$status" == 0 ]]; then
        xcrun notarytool log "$submission_id" "${args[@]}" "$log_dir/$(basename "$archive").log.json"
    else
        # An in-progress submission can time out without a log being available yet.
        xcrun notarytool log "$submission_id" "${args[@]}" "$log_dir/$(basename "$archive").log.json" || true
        fail "notarization was not accepted; see $result (submission $submission_id)"
    fi
    xcrun stapler staple "$staple_path"
    xcrun stapler validate "$staple_path"
}
