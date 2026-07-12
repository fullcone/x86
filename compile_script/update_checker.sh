#!/usr/bin/env bash
set -euo pipefail

source "$GITHUB_WORKSPACE/compile_script/main_and_feeds_url.sh"

mapfile -t unique_repositories < <(printf '%s\n' "${all_REPO_URLS[@]}" | awk 'NF' | sort -u)
if [ "${#unique_repositories[@]}" -eq 0 ]; then
  echo "::error::No source repositories were discovered."
  exit 1
fi

failures=0
records=()
for entry in "${unique_repositories[@]}"; do
  read -r repository branch <<< "$entry"
  ref="${branch:-HEAD}"
  echo "Checking $repository ($ref)"
  remote_line="$(git ls-remote "$repository" "$ref" | head -n 1 || true)"
  commit="$(awk '{print $1}' <<< "$remote_line")"
  if [[ ! "$commit" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "::error::Unable to resolve $repository at $ref"
    failures=$((failures + 1))
    continue
  fi
  records+=("${repository}@${ref}=${commit,,}")
done

if [ -z "${FC_TOKEN:-}" ]; then
  echo "::error::X86OPENWRT is required to inspect the private FullConeFlow source."
  failures=$((failures + 1))
else
  fullcone_commit="$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $FC_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/fullcone/fullcone-flow/commits?per_page=1" \
    | jq -r '.[0].sha' || true)"
  if [[ ! "$fullcone_commit" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "::error::Unable to resolve the private fullcone/fullcone-flow source."
    failures=$((failures + 1))
  else
    records+=("https://github.com/fullcone/fullcone-flow.git@HEAD=${fullcone_commit,,}")
  fi
fi

if [ "$failures" -ne 0 ]; then
  echo "::error::$failures source repository checks failed; refusing to publish a partial state."
  exit 1
fi

HASH_STRING="$(printf '%s\n' "${records[@]}" | sort | tr '\n' '|')"
FINAL_HASH="$(printf '%s' "$HASH_STRING" | sha256sum | awk '{print $1}')"
echo "Resolved ${#records[@]} repositories"
echo "Final source state: $FINAL_HASH"
echo "FINAL_HASH=$FINAL_HASH" >> "$GITHUB_OUTPUT"
echo "HASH_STRING=$HASH_STRING" >> "$GITHUB_OUTPUT"
