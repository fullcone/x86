#!/usr/bin/env bash
set -Eeuo pipefail

report_unexpected_failure() {
  local status="$?"
  local line="$1"
  local command="$2"
  trap - ERR
  echo "::error::Unexpected source-state failure at line $line (exit $status): $command" >&2
  exit "$status"
}
trap 'report_unexpected_failure "$LINENO" "$BASH_COMMAND"' ERR

source "$GITHUB_WORKSPACE/compile_script/main_and_feeds_url.sh"

mapfile -t unique_repositories < <(printf '%s\n' "${all_REPO_URLS[@]}" | awk 'NF' | sort -u)
if [ "${#unique_repositories[@]}" -eq 0 ]; then
  echo "::error::No source repositories were discovered."
  exit 1
fi

resolve_remote_commit() {
  local repository="$1"
  local ref="$2"
  local display_repository="${3:-$repository}"
  local max_attempts=3
  local attempt=1
  local delay_seconds
  local output
  local status
  local reason
  local commit

  while [ "$attempt" -le "$max_attempts" ]; do
    if output="$(GIT_TERMINAL_PROMPT=0 timeout 30s git ls-remote "$repository" "$ref" 2>&1)"; then
      status=0
    else
      status=$?
    fi

    commit="$(awk 'NR == 1 {print $1}' <<< "$output")"
    if [[ "$commit" =~ ^[0-9a-fA-F]{40}$ ]]; then
      printf '%s\n' "${commit,,}"
      return 0
    fi

    if [ "$status" -eq 0 ]; then
      reason="no matching 40-character commit"
    else
      reason="git exit $status"
    fi
    echo "::warning::Unable to resolve $display_repository at $ref (attempt $attempt/$max_attempts: $reason)" >&2
    if [ -n "$output" ]; then
      printf '%s\n' "$output" \
        | sed -E 's#https://[^/@[:space:]]+:[^/@[:space:]]+@github\.com/#https://github.com/#g' \
        | tail -n 3 \
        | sed 's/^/  /' >&2
    fi

    if [ "$attempt" -lt "$max_attempts" ]; then
      delay_seconds=$((attempt * 2))
      sleep "$delay_seconds"
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

failures=0
records=()
for entry in "${unique_repositories[@]}"; do
  read -r repository branch <<< "$entry"
  ref="${branch:-HEAD}"
  echo "Checking $repository ($ref)"
  if commit="$(resolve_remote_commit "$repository" "$ref")"; then
    records+=("${repository}@${ref}=${commit}")
  else
    echo "::error::Unable to resolve $repository at $ref after 3 attempts."
    failures=$((failures + 1))
  fi
done

if [ -z "${FC_TOKEN:-}" ]; then
  echo "::error::X86OPENWRT is required to inspect the private FullConeFlow source."
  failures=$((failures + 1))
else
  echo "::add-mask::$FC_TOKEN"
  fullcone_repository="https://x-access-token:${FC_TOKEN}@github.com/fullcone/fullcone-flow.git"
  echo "::add-mask::$fullcone_repository"
  echo "Private source token is present; using authenticated Git transport."
  if fullcone_commit="$(resolve_remote_commit \
    "$fullcone_repository" \
    HEAD \
    "https://github.com/fullcone/fullcone-flow.git")"; then
    records+=("https://github.com/fullcone/fullcone-flow.git@HEAD=${fullcone_commit}")
  else
    echo "::error::Unable to resolve the private fullcone/fullcone-flow source after 3 attempts."
    failures=$((failures + 1))
  fi
  unset fullcone_repository
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
