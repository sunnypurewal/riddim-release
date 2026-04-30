#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/init-labels.sh [OWNER/REPO ...]

Creates or updates the GitHub labels used by the autonomous PR agent loop.
When no repositories are provided, the defaults are used:
  RiddimSoftware/riddim-release
  RiddimSoftware/epac
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

repos=("$@")
if [[ ${#repos[@]} -eq 0 ]]; then
  repos=(
    "RiddimSoftware/riddim-release"
    "RiddimSoftware/epac"
  )
fi

labels=(
  "agent:build|E8A838|Triggers the developer workflow (initial build)"
  "agent:pause|B60205|Kill switch: short-circuits both workflows; no agent invocation"
  "agent:needs-human|D93F0B|Set by cap-hit or guard-script; blocks auto-merge until removed"
  "agent:attempt-1|FEF2C0|First build or fix-up attempt"
  "agent:attempt-2|FBD45C|Second fix-up attempt"
  "agent:attempt-3|F9A825|Third fix-up attempt (cap default; triggers needs-human on next)"
  "agent:rebase-attempt-1|C5DEF5|First stale-PR rebase attempt"
  "agent:rebase-attempt-2|8DB7E8|Second stale-PR rebase attempt"
  "agent:rebase-attempt-3|5319E7|Third stale-PR rebase attempt (default cap)"
  "agent:codeowners-veto|B60205|Rebase guard blocked conflicts in human-owned CODEOWNERS paths"
)

label_exists() {
  local repo="$1"
  local name="$2"

  gh api "repos/$repo/labels?per_page=100" --paginate --jq '.[].name' \
    | grep -Fxq "$name"
}

create_label() {
  local repo="$1" name="$2" color="$3" description="$4"

  if label_exists "$repo" "$name"; then
    echo "[skip] $name already exists on $repo"
    return
  fi

  gh label create "$name" --repo "$repo" --color "$color" --description "$description"
  echo "[created] $name on $repo"
}

for repo in "${repos[@]}"; do
  printf 'Initializing labels for %s\n' "$repo"
  for label in "${labels[@]}"; do
    IFS='|' read -r name color description <<<"$label"
    create_label "$repo" "$name" "$color" "$description"
  done

done
