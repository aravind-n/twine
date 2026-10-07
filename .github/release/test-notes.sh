#!/usr/bin/env bash
set -euo pipefail
repo="$PWD"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/release-notes-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
cd "$fixture"
cat > CHANGELOG.md <<'TXT'
## [Unreleased]
- Later change.
## [1.2.3] - 2026-09-30
### Added
- Released change.
## [1.2.2]
- Earlier change.
TXT
bash "$repo/.github/release/bundle-artifact.sh" notes 1.2.3 notes.md
printf '### Added\n- Released change.\n' > expected.md
cmp notes.md expected.md
printf '## 1.2.3\n- Change.\n[1.2.3]: link\n' > CHANGELOG.md
bash "$repo/.github/release/bundle-artifact.sh" notes 1.2.3 notes.md
printf '%s\n' '- Change.' > expected.md
cmp notes.md expected.md
for text in '## [Unreleased]' $'## [1.2.3]\n### Added\n' $'## [1.2.3]\n- First\n## [1.2.3]\n- Duplicate'; do
    printf '%s\n' "$text" > CHANGELOG.md
    if bash "$repo/.github/release/bundle-artifact.sh" notes 1.2.3 notes.md 2>/dev/null; then
        echo 'expected missing, empty, or duplicate release notes to fail' >&2
        exit 1
    fi
done
echo 'Changelog extraction checks passed'
