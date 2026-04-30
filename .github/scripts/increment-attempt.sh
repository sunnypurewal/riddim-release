#!/usr/bin/env bash
# Increments the agent:attempt-N label on a pull request.
#
# Usage: increment-attempt.sh <pr-number> [repo]
#   pr-number  Required. The pull request number to update.
#   repo       Optional. Defaults to $GITHUB_REPOSITORY.
#
# Behaviour:
#   - Reads the current attempt label (agent:attempt-1, agent:attempt-2,
#     agent:attempt-3, or none).
#   - Removes the old label (if any) and adds the next one.
#   - If already at agent:attempt-3: adds agent:needs-human instead and exits 1
#     (cap hit — no further automated attempts).
#   - The increment is idempotent: reads, computes, sets — never assumes
#     monotonic state. Safe to call concurrently.
#
# Exit codes:
#   0  Label bumped successfully.
#   1  Cap hit (was already at attempt-3); agent:needs-human added.
#   2  Usage error.

set -euo pipefail

usage() {
  echo "Usage: $0 <pull-request-number> [repo]" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

PR_NUMBER="$1"
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: pull-request-number must be a positive integer, got: $PR_NUMBER" >&2
  exit 2
fi

REPO="${2:-${GITHUB_REPOSITORY:-}}"
REPO_FLAG=""
if [[ -n "$REPO" ]]; then
  REPO_FLAG="--repo $REPO"
fi

# ---------------------------------------------------------------------------
# Read current labels
# ---------------------------------------------------------------------------

# shellcheck disable=SC2086
pr_labels="$(gh pr view "$PR_NUMBER" $REPO_FLAG --json labels --jq '[.labels[].name] | join(",")')"

current_attempt=0
if echo "$pr_labels" | grep -qF "agent:attempt-3"; then
  current_attempt=3
elif echo "$pr_labels" | grep -qF "agent:attempt-2"; then
  current_attempt=2
elif echo "$pr_labels" | grep -qF "agent:attempt-1"; then
  current_attempt=1
fi

echo "Current attempt label: ${current_attempt} (0 = none)"

# ---------------------------------------------------------------------------
# Cap hit
# ---------------------------------------------------------------------------

if (( current_attempt >= 3 )); then
  echo "Cap hit: already at agent:attempt-3. Adding agent:needs-human and exiting."
  # shellcheck disable=SC2086
  gh pr edit "$PR_NUMBER" $REPO_FLAG --add-label "agent:needs-human" 2>/dev/null || true
  # shellcheck disable=SC2086
  gh pr comment "$PR_NUMBER" $REPO_FLAG --body "**Automated attempt cap reached.**

This PR has reached the maximum of 3 automated fix-up attempts (\`agent:attempt-3\`). No further automated passes will run.

@SunnyPurewal please review the current state of the PR and either:
- Merge it manually if the changes look good.
- Push a corrective commit to reset the cycle.
- Close the PR if the approach needs rethinking.

Remove the \`agent:needs-human\` label to re-enable automation after intervening." 2>/dev/null || true
  exit 1
fi

# ---------------------------------------------------------------------------
# Bump the label
# ---------------------------------------------------------------------------

next_attempt=$(( current_attempt + 1 ))
next_label="agent:attempt-${next_attempt}"

# Remove old label if present
if (( current_attempt > 0 )); then
  old_label="agent:attempt-${current_attempt}"
  echo "Removing old label: $old_label"
  # shellcheck disable=SC2086
  gh pr edit "$PR_NUMBER" $REPO_FLAG --remove-label "$old_label" 2>/dev/null || true
fi

echo "Adding label: $next_label"
# shellcheck disable=SC2086
gh pr edit "$PR_NUMBER" $REPO_FLAG --add-label "$next_label"

echo "Attempt counter incremented to ${next_attempt}."
exit 0
