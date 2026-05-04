#!/usr/bin/env bash
# Create or update the pinned watcher-status PR comment for rebase automation.
#
# Usage:
#   update-watcher-status.sh <pr-number> <repo> <classification> <action> [details]
#
# The comment body starts with a stable HTML marker so future watcher runs update
# in place rather than spamming the PR timeline.

set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <pr-number> <repo> <classification> <action> [details]" >&2
  exit 2
fi

pr_number="$1"
repo="$2"
classification="$3"
action="$4"
details="${5:-}"
marker="<!-- riddim:watcher-status -->"

existing="$(gh api "repos/${repo}/issues/${pr_number}/comments" \
  --jq ".[] | select(.body | contains(\"${marker}\")) | .id" 2>/dev/null | tail -n 1 || true)"

body="$(cat <<BODY
${marker}
**Rebase Watcher status**

- Last classification: \`${classification}\`
- Last action: \`${action}\`
- Updated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

${details}

This comment is updated in place by \`riddim-release\` automation.
BODY
)"

if [[ -n "$existing" ]]; then
  gh api "repos/${repo}/issues/comments/${existing}" --method PATCH -f "body=${body}" >/dev/null
else
  gh pr comment "$pr_number" --repo "$repo" --body "$body" >/dev/null
fi
