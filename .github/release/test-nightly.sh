#!/usr/bin/env bash
set -euo pipefail

# Mock GitHub, never the release script: checks cannot publish tags or releases.
repo="$PWD"
mkdir -p target
fixture="$(mktemp -d "$repo/target/nightly-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/bin"
export MOCK_STATE="$fixture/state.json" MOCK_LOG="$fixture/commands.jsonl"
MOCK_SHA="$(git rev-parse HEAD)"
export MOCK_SHA
export GH_REPO=aravind-n/twine GITHUB_RUN_ID=123 GITHUB_OUTPUT="$fixture/output"
export NIGHTLY_WAIT_SECONDS=0
tag="nightly-20261005-${MOCK_SHA:0:12}"
export MOCK_TAG="$tag"
cat > "$fixture/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys

args = sys.argv[1:]
state_path = pathlib.Path(os.environ["MOCK_STATE"])
state = json.loads(state_path.read_text())
with open(os.environ["MOCK_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
sha = os.environ["MOCK_SHA"]
tag = os.environ["MOCK_TAG"]
result = None
if args[0] == "api":
    if state.get("api_failure"):
        sys.exit(1)
    path = next(arg for arg in args if arg.startswith("repos/"))
    if "/git/matching-refs/" in path:
        result = [{"ref": "refs/tags/" + path.split("/tags/")[1], "object": {"type": "commit", "sha": state["ref"]}}] if state.get("ref") else []
    elif "/artifacts?" in path:
        result = [{"artifacts": [{"name": "Twine-ci-" + sha, "expired": state.get("expired", False)}]}]
    elif "/workflows/ci.yml/runs" in path:
        state["polls"] = state.get("polls", 0) + 1
        status = "in_progress" if state.get("pending") or (state.get("wait") and state["polls"] == 1) else "completed"
        result = {"id": 456, "run_number": 42, "status": status, "conclusion": state.get("conclusion", "success"), "html_url": "https://example.test/ci/456"}
        if state.get("missing_ci"):
            result = ""
    elif "/actions/runs/123" in path:
        result = "2026-10-05T10:17:00Z"
    elif "/releases/tags/" in path:
        result = next(release for release in state["releases"] if release["tag_name"] == tag)
    elif path.endswith("/releases") or "/releases?" in path:
        result = [state.get("releases", [])]
    else:
        raise RuntimeError("unexpected API request: " + repr(args))
elif args[:2] == ["release", "create"]:
    state["releases"] = [{"tag_name": tag, "target_commitish": sha, "prerelease": True, "draft": True, "created_at": "2026-10-05T10:17:00Z", "assets": []}]
elif args[:2] == ["release", "edit"]:
    if "--draft=false" in args:
        if state.get("edit_failure"):
            sys.exit(1)
        state["releases"][0]["draft"] = False
        state["ref"] = sha
elif args[:2] == ["release", "delete-asset"]:
    state["releases"][0]["assets"] = [asset for asset in state["releases"][0]["assets"] if asset["name"] != args[3]]
elif args[:2] == ["release", "upload"]:
    if state.get("upload_failure"):
        sys.exit(1)
    state["releases"][0]["assets"] = [{"name": pathlib.Path(path).name, "size": pathlib.Path(path).stat().st_size} for path in args[3:]]
    if state.get("bad_upload"):
        state["releases"][0]["assets"][0]["size"] += 1
else:
    raise RuntimeError("unexpected command: " + repr(args))
state_path.write_text(json.dumps(state))
if result is not None:
    print(result if isinstance(result, str) else json.dumps(result))
PY
cat > "$fixture/bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$fixture/bin/gh" "$fixture/bin/sleep"
export PATH="$fixture/bin:$PATH"

reset() {
    : > "$GITHUB_OUTPUT"
    : > "$MOCK_LOG"
    python3 - "$1" <<'PY'
import json, os, pathlib, sys
tag, sha = os.environ["MOCK_TAG"], os.environ["MOCK_SHA"]
names = [f"Twine-{tag}-macos-universal.dmg", f"libtwinecore-{tag}-macos-universal.tar.gz", f"Twine-{tag}-symbols.tar.gz", f"twine-{tag}-source.tar.gz", "SHA256SUMS"]
release = {"tag_name": tag, "target_commitish": sha, "draft": False, "prerelease": True, "created_at": "2026-10-05T10:17:00Z", "assets": [{"name": name, "size": 1} for name in names]}
state = {"releases": []}
case = sys.argv[1]
if case in ("published", "draft", "old_draft", "incomplete", "conflict", "empty", "stable_channel", "legacy_zip"):
    state["releases"] = [release]
    state["ref"] = sha
    if case in ("draft", "old_draft"):
        release["draft"] = True
        release["assets"] = [{"name": "unexpected.txt", "size": 1}]
    if case == "old_draft": release["tag_name"] = tag.replace("20261005", "20261004")
    if case == "incomplete": release["assets"].pop()
    if case == "conflict": release["target_commitish"] = "0" * 40
    if case == "empty": release["assets"][0]["size"] = 0
    if case == "stable_channel": release["prerelease"] = False
    if case == "legacy_zip": release["assets"][0]["name"] = names[0].replace(".dmg", ".zip")
elif case == "tag_conflict": state["ref"] = "0" * 40
elif case == "ci_failure": state["conclusion"] = "failure"
elif case != "new": state[case] = True
pathlib.Path(os.environ["MOCK_STATE"]).write_text(json.dumps(state))
PY
}
run() { bash .github/release/nightly.sh "$@"; }
reject() {
    if run "$@" > "$fixture/rejected.log" 2>&1; then
        echo "expected rejection: $*" >&2
        exit 1
    fi
}

reset new
run guard "$fixture/notes.md"
grep -qx "sha=$MOCK_SHA" "$GITHUB_OUTPUT"
grep -qx "tag=$tag" "$GITHUB_OUTPUT"
grep -qx 'build_run=456' "$GITHUB_OUTPUT"
grep -qx 'build_number=42' "$GITHUB_OUTPUT"
grep -qx 'publish=true' "$GITHUB_OUTPUT"
grep -q "$MOCK_SHA" "$fixture/notes.md"
grep -q 'Open the DMG and drag Twine.app to Applications' "$fixture/notes.md"
reset expired
run guard "$fixture/notes.md"
grep -qx 'build_run=' "$GITHUB_OUTPUT"
grep -qx 'ci_run=456' "$GITHUB_OUTPUT"
reset published
run guard "$fixture/notes.md"
grep -qx 'publish=false' "$GITHUB_OUTPUT"
if grep -q '/actions/' "$MOCK_LOG"; then echo 'published commit unexpectedly queried CI' >&2; exit 1; fi
reset draft
run guard "$fixture/notes.md"
grep -qx "tag=$tag" "$GITHUB_OUTPUT"
grep -qx 'publish=true' "$GITHUB_OUTPUT"
reset old_draft
run guard "$fixture/notes.md"
grep -qx "tag=nightly-20261004-${MOCK_SHA:0:12}" "$GITHUB_OUTPUT"
grep -q 'Twine Nightly — 20261004' "$fixture/notes.md"
for case in ci_failure pending missing_ci incomplete conflict empty stable_channel legacy_zip tag_conflict api_failure; do
    reset "$case"
    reject guard "$fixture/notes.md"
    if grep -q 'publish=true' "$GITHUB_OUTPUT"; then echo 'rejected commit allowed publication' >&2; exit 1; fi
done
reset wait
NIGHTLY_WAIT_SECONDS=30 run guard "$fixture/notes.md"
grep -qx 'publish=true' "$GITHUB_OUTPUT"

mkdir "$fixture/assets"
for name in "Twine-$tag-macos-universal.dmg" "libtwinecore-$tag-macos-universal.tar.gz" \
    "Twine-$tag-symbols.tar.gz" "twine-$tag-source.tar.gz"; do
    printf 'fixture asset\n' > "$fixture/assets/$name"
done
(cd "$fixture/assets" && shasum -a 256 ./*.dmg ./*.tar.gz > SHA256SUMS)
for case in new draft; do
    reset "$case"
    run publish "$tag" "$fixture/assets" "$fixture/notes.md"
    python3 - <<'PY'
import json, os, pathlib
state = json.loads(pathlib.Path(os.environ["MOCK_STATE"]).read_text())
assert state["releases"][0]["draft"] is False
assert state["ref"] == os.environ["MOCK_SHA"]
commands = [json.loads(line) for line in pathlib.Path(os.environ["MOCK_LOG"]).read_text().splitlines()]
assert all("--latest=false" in args and "--prerelease" in args for args in commands if args[:2] in (["release", "create"], ["release", "edit"]))
assert any(args[:2] == ["release", "upload"] for args in commands)
PY
done
reset published
run publish "$tag" "$fixture/assets" "$fixture/notes.md"
if grep -q '"release",' "$MOCK_LOG"; then echo 'published nightly was mutated' >&2; exit 1; fi
for case in tag_conflict conflict incomplete legacy_zip upload_failure bad_upload edit_failure api_failure; do
    reset "$case"
    reject publish "$tag" "$fixture/assets" "$fixture/notes.md"
done
reset new
printf 'damaged\n' >> "$fixture/assets/Twine-$tag-macos-universal.dmg"
reject publish "$tag" "$fixture/assets" "$fixture/notes.md"
if grep -q '"release",' "$MOCK_LOG"; then echo 'damaged local asset was uploaded' >&2; exit 1; fi
echo 'Nightly guard and publication checks passed'
