#!/usr/bin/env bash
# get-mergeable-state.sh — Poll the GitHub API until mergeable is non-null,
# then emit the mergeable_state.
#
# Usage: get-mergeable-state.sh <pr-number> [repo]
#   pr-number  Required. The pull request number to inspect.
#   repo       Optional. Defaults to $GH_REPO or $GITHUB_REPOSITORY.
#
# Output (stdout): one of:
#   clean | behind | dirty | blocked | unstable | unknown
#
# Exit codes:
#   0  State determined (including 'unknown' after retry exhaustion).
#   1  Usage error or missing argument.
#
# Environment:
#   GH_TOKEN       Required. GitHub token with `repo` read access.
#   GH_REPO        Optional. Overrides $GITHUB_REPOSITORY.
#   MAX_ATTEMPTS   Optional. Number of poll attempts (default 6).
#   POLL_INTERVAL  Optional. Seconds between attempts (default 5).
#
# Notes:
#   GitHub recomputes mergeable asynchronously after a push to the base branch.
#   The mergeable field is null during recomputation (typically 10-30 s under
#   normal load). This script retries until mergeable is non-null or the retry
#   budget is exhausted. On exhaustion it emits 'unknown' and exits 0 — the
#   caller should treat 'unknown' as a transient signal and allow the cron
#   backstop to retry.

set -euo pipefail

# ---------------------------------------------------------------------------
# Args + defaults
# ---------------------------------------------------------------------------

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <pr-number> [repo]" >&2
  exit 1
fi

PR_NUMBER="$1"
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: pr-number must be a positive integer, got: $PR_NUMBER" >&2
  exit 1
fi

REPO="${2:-${GH_REPO:-${GITHUB_REPOSITORY:-}}}"
if [[ -z "$REPO" ]]; then
  echo "Error: repo must be provided as arg 2, GH_REPO, or GITHUB_REPOSITORY env var." >&2
  exit 1
fi

MAX_ATTEMPTS="${MAX_ATTEMPTS:-6}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

# ---------------------------------------------------------------------------
# Poll
# ---------------------------------------------------------------------------

attempt=0
while (( attempt < MAX_ATTEMPTS )); do
  attempt=$(( attempt + 1 ))

  response="$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" \
    --jq '{mergeable: .mergeable, mergeable_state: .mergeable_state}' 2>/dev/null || true)"

  if [[ -z "$response" ]]; then
    echo "::warning::get-mergeable-state: gh api returned empty response on attempt ${attempt}/${MAX_ATTEMPTS}" >&2
    if (( attempt < MAX_ATTEMPTS )); then
      sleep "$POLL_INTERVAL"
    fi
    continue
  fi

  mergeable="$(printf '%s' "$response" | jq -r '.mergeable')"
  mergeable_state="$(printf '%s' "$response" | jq -r '.mergeable_state')"

  if [[ "$mergeable" == "null" || -z "$mergeable" ]]; then
    echo "::debug::get-mergeable-state: mergeable=null on attempt ${attempt}/${MAX_ATTEMPTS}, retrying..." >&2
    if (( attempt < MAX_ATTEMPTS )); then
      sleep "$POLL_INTERVAL"
    fi
    continue
  fi

  # Normalise GitHub's mergeable_state values to our documented set.
  case "$mergeable_state" in
    clean)     echo "clean";     exit 0 ;;
    behind)    echo "behind";    exit 0 ;;
    dirty)     echo "dirty";     exit 0 ;;
    blocked)   echo "blocked";   exit 0 ;;
    unstable)  echo "unstable";  exit 0 ;;
    # draft, unknown, or any future GitHub state → unknown
    *)         echo "unknown";   exit 0 ;;
  esac
done

# Retry budget exhausted.
echo "::warning::get-mergeable-state: mergeable still null after ${MAX_ATTEMPTS} attempts for PR #${PR_NUMBER} in ${REPO}. Treating as unknown." >&2
echo "unknown"
exit 0
