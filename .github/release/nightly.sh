#!/usr/bin/env bash
set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }
repo="${GH_REPO:?GH_REPO required}"
sha="$(git rev-parse HEAD)"
short_sha="${sha:0:12}"
repo_url="${GITHUB_SERVER_URL:-https://github.com}/$repo"

releases() {
    gh api --paginate --slurp "repos/$repo/releases?per_page=100" | jq 'add'
}

expected_assets() {
    printf '%s\n' "Twine-$1-macos-universal.zip" "libtwinecore-$1-macos-universal.tar.gz" \
        "Twine-$1-symbols.tar.gz" "twine-$1-source.tar.gz" SHA256SUMS | sort
}

check_tag() {
    local tag="$1" required="$2" refs
    refs="$(gh api "repos/$repo/git/matching-refs/tags/$tag" \
        | jq --arg ref "refs/tags/$tag" '[.[] | select(.ref == $ref)]')"
    if [[ "$(jq length <<< "$refs")" == 0 ]]; then
        [[ "$required" == false ]] || fail "published nightly is missing its tag: $tag"
    else
        jq -e --arg sha "$sha" 'length == 1 and .[0].object.type == "commit" and .[0].object.sha == $sha' \
            <<< "$refs" >/dev/null || fail "tag belongs to another commit: $tag"
    fi
}

check_release() {
    local release="$1" tag
    tag="$(jq -r .tag_name <<< "$release")"
    jq -e --arg sha "$sha" '.prerelease and .target_commitish == $sha' <<< "$release" >/dev/null \
        || fail "release belongs to another commit or channel: $tag"
    check_tag "$tag" "$(jq '.draft | not' <<< "$release")"
}

check_assets() {
    local release="$1" tag names
    tag="$(jq -r .tag_name <<< "$release")"
    names="$(jq -r '.assets[].name' <<< "$release" | sort)"
    [[ "$names" == "$(expected_assets "$tag")" ]] || fail "incorrect asset set: $tag"
    jq -e 'all(.assets[]; .size > 0)' <<< "$release" >/dev/null || fail "empty release asset: $tag"
}

case "${1:-}" in
    guard)
        notes="${2:?notes destination required}"
        output="${GITHUB_OUTPUT:?GITHUB_OUTPUT required}"
        echo "sha=$sha" >> "$output"
        all_releases="$(releases)"
        matching="$(jq --arg suffix "-$short_sha" \
            '[.[] | select(.tag_name | test("^nightly-[0-9]{8}-[0-9a-f]{12}$")) | select(.tag_name | endswith($suffix))]' \
            <<< "$all_releases")"
        while IFS= read -r release; do
            check_release "$release"
            if [[ "$(jq .draft <<< "$release")" == false ]]; then
                check_assets "$release"
                echo "tag=$(jq -r .tag_name <<< "$release")" >> "$output"
                echo 'publish=false' >> "$output"
                echo "Already published: $repo_url/releases/tag/$(jq -r .tag_name <<< "$release")"
                exit 0
            fi
        done < <(jq -c '.[]' <<< "$matching")

        # The run's creation date remains fixed across retries and midnight boundaries.
        created_at="$(gh api "repos/$repo/actions/runs/${GITHUB_RUN_ID:?GITHUB_RUN_ID required}" --jq .created_at)"
        nightly_date="$(python3 -c 'import datetime, sys, zoneinfo; print(datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00")).astimezone(zoneinfo.ZoneInfo("America/Los_Angeles")).strftime("%Y%m%d"))' "$created_at")"
        tag="$(jq -r 'sort_by(.created_at) | last | .tag_name // empty' <<< "$matching")"
        tag="${tag:-nightly-$nightly_date-$short_sha}"
        nightly_date="${tag#nightly-}"
        nightly_date="${nightly_date%-*}"
        echo "tag=$tag" >> "$output"
        check_tag "$tag" false

        deadline=$((SECONDS + ${NIGHTLY_WAIT_SECONDS:-1800}))
        while :; do
            run="$(gh api "repos/$repo/actions/workflows/ci.yml/runs" --method GET \
                -f branch=main -f event=push -f head_sha="$sha" -f per_page=100 \
                --jq '.workflow_runs | sort_by(.run_number) | last // empty')"
            if [[ -n "$run" && "$(jq -r .status <<< "$run")" == completed ]]; then
                jq -e '.conclusion == "success"' <<< "$run" >/dev/null \
                    || fail "main CI did not pass: $(jq -r .html_url <<< "$run")"
                break
            fi
            (( SECONDS < deadline )) || fail "timed out waiting for main CI on $sha"
            sleep 30
        done
        ci_run="$(jq -r .id <<< "$run")"
        build_number="$(jq -r .run_number <<< "$run")"
        [[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail 'invalid CI build number'
        build_run="$ci_run"
        available="$(gh api --paginate --slurp "repos/$repo/actions/runs/$ci_run/artifacts?per_page=100" \
            | jq --arg name "Twine-ci-$sha" '[.[].artifacts[] | select(.name == $name and .expired == false)] | length')"
        if [[ "$available" == 0 ]]; then build_run=''; fi
        {
            echo "ci_run=$ci_run"
            echo "build_run=$build_run"
            echo "build_number=$build_number"
            echo 'publish=true'
        } >> "$output"

        previous=''
        while IFS= read -r previous_tag; do
            previous_sha="$(git rev-parse "refs/tags/$previous_tag^{commit}")"
            if git merge-base --is-ancestor "$previous_sha" "$sha"; then previous="$previous_tag"; break; fi
        done < <(jq -r '[.[] | select(.draft == false and .prerelease and (.tag_name | test("^nightly-[0-9]{8}-[0-9a-f]{12}$")))]
            | sort_by(.published_at) | reverse | .[].tag_name' <<< "$all_releases")
        {
            echo "Twine Nightly — $nightly_date"
            echo
            echo "Commit: $sha"
            echo "Build number: $build_number"
            echo "CI: $repo_url/actions/runs/$ci_run"
            echo
            echo 'Requires macOS 26+, on Apple Silicon or Intel. The app is ad hoc signed and not notarized.'
            echo 'Quit Twine and replace Twine.app. This nightly uses your existing saved data and settings.'
            echo 'Installation instructions are included in the ZIP. Download SHA256SUMS to verify the archives.'
            echo
            if [[ -n "$previous" ]]; then
                echo "Changes: $repo_url/compare/$previous...$tag"
                git log --format='- %s (%h)' "$previous_sha..$sha"
            else
                echo 'Recent changes (first nightly):'
                git log -20 --format='- %s (%h)' "$sha"
            fi
        } > "$notes"
        ;;
    publish)
        tag="${2:?nightly tag required}"
        assets="${3:?assets directory required}"
        notes="${4:?notes file required}"
        [[ "$tag" =~ ^nightly-[0-9]{8}-[0-9a-f]{12}$ && "$tag" == *-"$short_sha" ]] \
            || fail 'nightly tag does not identify this commit'
        check_tag "$tag" false
        # Require exactly the expected files; directories and untracked extras cannot be uploaded.
        names="$(find "$assets" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort)"
        [[ "$names" == "$(expected_assets "$tag")" ]] || fail 'incorrect local asset set'
        while IFS= read -r name; do
            [[ -f "$assets/$name" && ! -L "$assets/$name" ]] || fail "expected a regular asset file: $name"
        done < <(expected_assets "$tag")
        (cd "$assets" && shasum -a 256 -c SHA256SUMS)
        release="$(releases | jq --arg tag "$tag" '.[] | select(.tag_name == $tag)')"
        if [[ -n "$release" ]]; then
            check_release "$release"
            if [[ "$(jq .draft <<< "$release")" == false ]]; then
                check_assets "$release"
                echo "Already published: $repo_url/releases/tag/$tag"
                exit 0
            fi
            gh release edit "$tag" --draft --prerelease --latest=false --notes-file "$notes"
            # Remove unexpected draft assets left by an earlier interrupted attempt.
            while IFS= read -r name; do
                gh release delete-asset "$tag" "$name" --yes
            done < <(jq -r '.assets[].name' <<< "$release")
        else
            gh release create "$tag" --draft --prerelease --latest=false --target "$sha" \
                --title "Twine Nightly — ${tag#nightly-}" --notes-file "$notes"
        fi
        gh release upload "$tag" "$assets"/*
        release="$(releases | jq --arg tag "$tag" '.[] | select(.tag_name == $tag)')"
        check_release "$release"
        check_assets "$release"
        while IFS= read -r path; do
            size="$(wc -c < "$assets/$path" | tr -d ' ')"
            jq -e --arg name "$path" --argjson size "$size" \
                'any(.assets[]; .name == $name and .size == $size)' <<< "$release" >/dev/null \
                || fail "uploaded asset size differs: $path"
        done < <(expected_assets "$tag")
        gh release edit "$tag" --draft=false --prerelease --latest=false
        release="$(gh api "repos/$repo/releases/tags/$tag")"
        check_release "$release"
        check_assets "$release"
        [[ "$(jq .draft <<< "$release")" == false ]] || fail 'nightly is still a draft'
        echo "Published: $repo_url/releases/tag/$tag"
        ;;
    *) fail 'usage: nightly.sh guard NOTES | publish TAG ASSETS NOTES' ;;
esac
