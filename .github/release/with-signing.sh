#!/usr/bin/env bash
set -euo pipefail

# Keep private keys and notary credentials scoped to one command, including on persistent runners.
: "${APPLE_CERTIFICATE_P12_BASE64:?Apple certificate secret is required}"
: "${APPLE_CERTIFICATE_PASSWORD:?Apple certificate password is required}"
: "${APPLE_SIGNING_IDENTITY:?Developer ID Application identity is required}"
: "${APPLE_TEAM_ID:?Apple team ID is required}"
: "${APPLE_ID:?Apple account email is required}"
: "${APPLE_NOTARIZATION_PASSWORD:?Apple app-specific password is required}"
[[ $# -gt 0 ]] || { echo 'usage: with-signing.sh COMMAND [ARGUMENTS...]' >&2; exit 1; }
umask 077
credentials="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/twine-signing.XXXXXX")"
export TWINE_SIGNING_KEYCHAIN="$credentials/signing.keychain-db"
cleanup() {
    if [[ -f "$TWINE_SIGNING_KEYCHAIN" ]]; then
        security delete-keychain "$TWINE_SIGNING_KEYCHAIN" || echo 'warning: could not delete signing keychain' >&2
    fi
    rm -rf "$credentials"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

keychain_password="$(openssl rand -hex 32)"
security create-keychain -p "$keychain_password" "$TWINE_SIGNING_KEYCHAIN"
security set-keychain-settings -lut 21600 "$TWINE_SIGNING_KEYCHAIN"
security unlock-keychain -p "$keychain_password" "$TWINE_SIGNING_KEYCHAIN"
printf '%s' "$APPLE_CERTIFICATE_P12_BASE64" | base64 --decode > "$credentials/certificate.p12"
security import "$credentials/certificate.p12" -P "$APPLE_CERTIFICATE_PASSWORD" \
    -k "$TWINE_SIGNING_KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$TWINE_SIGNING_KEYCHAIN" >/dev/null
rm "$credentials/certificate.p12"
export TWINE_SIGNING_MODE=developer-id TWINE_NOTARY_PROFILE=twine-release
xcrun notarytool store-credentials "$TWINE_NOTARY_PROFILE" --keychain "$TWINE_SIGNING_KEYCHAIN" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_NOTARIZATION_PASSWORD"
# The packaging command only needs the identity, team, and keychain profile.
unset APPLE_CERTIFICATE_P12_BASE64 APPLE_CERTIFICATE_PASSWORD APPLE_NOTARIZATION_PASSWORD APPLE_ID keychain_password
"$@"
