#!/usr/bin/env bash
# update-watcher-status.sh — Upsert a pinned status comment on a PR.
#
# Usage:
#   update-watcher-status.sh <owner> <repo> <pr_number> <state> <action>
#
# The comment body uses the marker <!-- riddim:watcher-status --> so repeated
# calls update the same comment rather than adding new ones.
#
# Environment:
#   GH_TOKEN  — GitHub token with pull_requests:write on <owner>/<repo>

set -euo pipefail

usage() {
  echo "Usage: $0 <owner> <repo> <pr_number> <state> <action>" >&2
  echo "  state   — e.g. 'guard-blocked', 'rebased', 'conflict-resolved'" >&2
  echo "  action  — e.g. 'agent:needs-human applied', 'pushed rebase', 'no action'" >&2
}

if [[ $# -lt 5 ]]; then
  usage
  exit 2
fi

OWNER="$1"
REPO="$2"
PR_NUMBER="$3"
STATE="$4"
ACTION="$5"

FULL_REPO="${OWNER}/${REPO}"
MARKER="<!-- riddim:watcher-status -->"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

BODY="${MARKER}
**Last watcher run:** ${TIMESTAMP}
**State:** ${STATE}
**Action:** ${ACTION}"

# Find existing comment with the marker
existing_id="$(gh api "repos/${FULL_REPO}/issues/${PR_NUMBER}/comments" \
  --jq ".[] | select(.body | contains(\"${MARKER}\")) | .id" 2>/dev/null \
  | tail -n 1 || true)"

if [[ -n "$existing_id" ]]; then
  gh api --method PATCH \
    "/repos/${FULL_REPO}/issues/comments/${existing_id}" \
    --field "body=${BODY}" \
    >/dev/null
  echo "Updated existing watcher-status comment (id=${existing_id}) on ${FULL_REPO}#${PR_NUMBER}."
else
  gh pr comment "$PR_NUMBER" --repo "$FULL_REPO" --body "$BODY" >/dev/null
  echo "Created new watcher-status comment on ${FULL_REPO}#${PR_NUMBER}."
fi
