#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/init-labels.sh [OWNER/REPO ...]

Creates or updates the GitHub labels used by the autonomous PR agent loop.
When no repositories are provided, the RIDDIM-91 host and first consumer are used:
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
  "agent:build|fb8c00|Triggers the autonomous developer workflow initial build."
  "agent:pause|6a737d|Manual override that short-circuits autonomous workflows."
  "agent:needs-human|d73a4a|Blocks automation when guardrails or attempt caps require a human."
  "agent:attempt-1|ffd8a8|Autonomous workflow attempt counter: first attempt."
  "agent:attempt-2|ffb56b|Autonomous workflow attempt counter: second attempt."
  "agent:attempt-3|ff922b|Autonomous workflow attempt counter: third and final default attempt."
)

ensure_label() {
  local repo="$1"
  local name="$2"
  local color="$3"
  local description="$4"

  gh label create "$name" --repo "$repo" --color "$color" --description "$description" --force >/dev/null
  printf '%s: ensured %s\n' "$repo" "$name"
}

for repo in "${repos[@]}"; do
  printf 'Initializing labels for %s\n' "$repo"
  for label in "${labels[@]}"; do
    IFS='|' read -r name color description <<<"$label"
    ensure_label "$repo" "$name" "$color" "$description"
  done
done
