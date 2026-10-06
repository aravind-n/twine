#!/usr/bin/env bash
set -euo pipefail

if [[ "$CHANGES_RESULT" != success ]]; then
    echo "::error::changes was $CHANGES_RESULT (expected success)"
    exit 1
fi

failed=0
check_job() {
    local name="$1" selected="$2" result="$3" expected
    case "$selected" in
        true) expected=success ;;
        false) expected=skipped ;;
        *)
            echo "::error::$name has invalid selection '$selected'"
            failed=1
            return
            ;;
    esac
    if [[ "$result" != "$expected" ]]; then
        echo "::error::$name was $result (expected $expected)"
        failed=1
    else
        echo "$name: $result"
    fi
}

check_job rust-lint "$LIBRARIES_SELECTED" "$RUST_LINT_RESULT"
check_job native-checks "$NATIVE_SELECTED" "$NATIVE_CHECKS_RESULT"
check_job cargo-audit "$LOCKFILE_SELECTED" "$CARGO_AUDIT_RESULT"
check_job actionlint "$WORKFLOWS_SELECTED" "$ACTIONLINT_RESULT"

case "$SITE_SELECTED:$SWIFT_DOCS_CACHED" in
    true:true)
        check_job site-cached true "$SITE_CACHED_RESULT"
        check_job site-generated false "$SITE_GENERATED_RESULT"
        ;;
    true:false)
        check_job site-cached false "$SITE_CACHED_RESULT"
        check_job site-generated true "$SITE_GENERATED_RESULT"
        ;;
    false:true|false:false)
        check_job site-cached false "$SITE_CACHED_RESULT"
        check_job site-generated false "$SITE_GENERATED_RESULT"
        ;;
    *)
        echo "::error::invalid website selection '$SITE_SELECTED:$SWIFT_DOCS_CACHED'"
        failed=1
        ;;
esac
exit "$failed"
