#!/usr/bin/env bash
# Report failed and retried tests from Xcode result bundles as GitHub annotations and a job summary.
# Usage: report-tests.sh RESULT.xcresult...
# It only reports, so it exits 0 whether or not tests failed.
set -euo pipefail

summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
root="${GITHUB_WORKSPACE:-$PWD}/"

results="[]"
for bundle in "$@"; do
    [[ -d "$bundle" ]] || continue
    if ! tests="$(xcrun xcresulttool get test-results tests --path "$bundle")"; then
        echo "::warning title=Test report::Could not read $bundle"
        continue
    fi
    results="$(jq -c --argjson results "$results" '$results + [.]' <<<"$tests")"
done

# One entry per failed test, and per test that passed only after a failed attempt.
cases="$(jq -c --arg root "$root" '
    [.[] | .testNodes[] | .. | objects
        | select(.nodeType? == "UI test bundle" or .nodeType? == "Unit test bundle")
        | .nodeType as $kind | .. | objects | select(.nodeType? == "Test Case")
        | {
            ui: ($kind == "UI test bundle"),
            name: (.name | rtrimstr("()")),
            result,
            retried: ([.children[]? | select(.nodeType == "Repetition" and .result == "Failed")] | length > 0),
            failure: ([.. | objects | select(.nodeType? == "Failure Message") | {
                message: (.name | split("\n")[0]),
                file: ((.sourceLocation.filePath // "") | ltrimstr($root)),
                line: (.sourceLocation.lineNumber // 0)
            }] | first)
        }
        | select(.result == "Failed" or (.result == "Passed" and .retried))]
' <<<"$results")"

# Workflow commands need %, CR and LF escaped, and properties also need : and , escaped.
jq -r '
    def message: gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
    def property: message | gsub(":"; "%3A") | gsub(","; "%2C");
    .[] | (if .result == "Failed" then "error" else "warning" end) as $level
    | ([if (.failure.file // "") != "" then "file=\(.failure.file | property),line=\(.failure.line)" else empty end,
        "title=\(.name | property) \(if $level == "error" then "failed" else "passed on retry" end)"]
       | join(",")) as $properties
    | "::\($level) \($properties)::\(.failure.message // "" | message)"
' <<<"$cases"

[[ "$(jq length <<<"$cases")" -gt 0 ]] || exit 0
jq -r --arg url "${RESULTS_URL:-}" '
    def cell: gsub("\\|"; "\\|") | gsub("`"; "'"'"'") | .[0:300];
    def failure: if .failure then "\(.failure.file):\(.failure.line): \(.failure.message | cell)" else "" end;
    def command: if .ui then "`make ui-test ONLY=\(.name)`" else "`make test-app`" end;
    (map(select(.result == "Failed")) as $failed | if ($failed | length) > 0 then
        "### Failed tests", "", "| Test | Failure | Run locally |", "| --- | --- | --- |",
        ($failed[] | "| `\(.name)` | \(failure) | \(command) |"), ""
    else empty end),
    (map(select(.result == "Passed")) as $retried | if ($retried | length) > 0 then
        "### Passed on retry", "", "These tests failed once and passed when retried.", "",
        "| Test | First failure |", "| --- | --- |",
        ($retried[] | "| `\(.name)` | \(failure) |"), ""
    else empty end),
    (if $url != "" then "[Download the result bundles](\($url)) to open them in Xcode.", "" else empty end)
' <<<"$cases" >> "$summary"
