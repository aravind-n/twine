#!/usr/bin/env bash
set -euo pipefail

gate="$PWD/.github/ci/gate.sh"
baseline() {
    export CHANGES_RESULT=success
    export LIBRARIES_SELECTED=false NATIVE_SELECTED=false LOCKFILE_SELECTED=false
    export WORKFLOWS_SELECTED=false SITE_SELECTED=false SWIFT_DOCS_CACHED=false
    export RUST_LINT_RESULT=skipped NATIVE_CHECKS_RESULT=skipped CARGO_AUDIT_RESULT=skipped
    export ACTIONLINT_RESULT=skipped SITE_CACHED_RESULT=skipped SITE_GENERATED_RESULT=skipped
}
pass() { bash "$gate" >/dev/null; }
reject() {
    if bash "$gate" >/dev/null 2>&1; then
        echo "CI gate unexpectedly passed: $*" >&2
        exit 1
    fi
}

baseline
pass # An unrelated PR needs no selected checks.

for pair in \
    LIBRARIES_SELECTED:RUST_LINT_RESULT \
    NATIVE_SELECTED:NATIVE_CHECKS_RESULT \
    LOCKFILE_SELECTED:CARGO_AUDIT_RESULT \
    WORKFLOWS_SELECTED:ACTIONLINT_RESULT
do
    selection="${pair%:*}"
    result="${pair#*:}"
    baseline
    export "$selection=true" "$result=success"
    pass
    for outcome in failure cancelled skipped ''; do
        export "$result=$outcome"
        reject "$result=$outcome"
    done
    baseline
    export "$result=success"
    reject "unselected $result succeeded"
    baseline
    export "$selection="
    reject "missing $selection"
done

for cached in true false; do
    baseline
    export SITE_SELECTED=true SWIFT_DOCS_CACHED="$cached"
    selected=SITE_GENERATED_RESULT
    if [[ "$cached" == true ]]; then selected=SITE_CACHED_RESULT; fi
    export "$selected=success"
    pass
    for outcome in failure cancelled skipped; do
        export "$selected=$outcome"
        reject "$selected=$outcome"
    done
done

baseline
export LIBRARIES_SELECTED=true NATIVE_SELECTED=true LOCKFILE_SELECTED=true WORKFLOWS_SELECTED=true
export SITE_SELECTED=true SWIFT_DOCS_CACHED=false
export RUST_LINT_RESULT=success NATIVE_CHECKS_RESULT=success CARGO_AUDIT_RESULT=success
export ACTIONLINT_RESULT=success SITE_GENERATED_RESULT=success
pass
export SITE_CACHED_RESULT=success
reject 'both website paths ran'

for outcome in failure cancelled skipped; do
    baseline
    export CHANGES_RESULT="$outcome"
    reject "change detection $outcome"
done
baseline
export SWIFT_DOCS_CACHED=
reject 'missing documentation cache selection'
echo 'CI gate tests passed'
