#!/usr/bin/env bash
# Usage: ./scripts/init-labels.sh <owner/repo>
# Idempotent: safe to re-run; skips labels that already exist.
set -euo pipefail

REPO="${1:?Usage: $0 <owner/repo>}"

create_label() {
  local name="$1" color="$2" description="$3"
  if gh label list --repo "$REPO" --json name --jq '.[].name' | grep -qx "$name"; then
    echo "[skip] $name already exists on $REPO"
  else
    gh label create "$name" --repo "$REPO" --color "$color" --description "$description"
    echo "[created] $name on $REPO"
  fi
}

create_label "agent:build"        "E8A838" "Triggers the developer workflow (initial build)"
create_label "agent:pause"        "B60205" "Kill switch: short-circuits both workflows; no agent invocation"
create_label "agent:needs-human"  "D93F0B" "Set by cap-hit or guard-script; blocks auto-merge until removed"
create_label "agent:attempt-1"    "FEF2C0" "First build or fix-up attempt"
create_label "agent:attempt-2"    "FBD45C" "Second fix-up attempt"
create_label "agent:attempt-3"    "F9A825" "Third fix-up attempt (cap default; triggers needs-human on next)"

echo "Done. All agent:* labels verified on $REPO."
