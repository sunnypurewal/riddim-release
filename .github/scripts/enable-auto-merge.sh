#!/usr/bin/env bash
# Enables GitHub auto-merge for the PR updated by the developer fix-up workflow.

set -euo pipefail

trigger_type="${TRIGGER_TYPE:-}"
pr_number="${PR_NUMBER:-}"
pr_head_before="${PR_HEAD_BEFORE:-}"

case "$trigger_type" in
  changes_requested|pr-fixup) ;;
  "")
    echo "Error: TRIGGER_TYPE is required" >&2
    exit 2
    ;;
  *)
    echo "Error: unsupported TRIGGER_TYPE: $trigger_type" >&2
    exit 2
    ;;
esac

if [[ -z "$pr_number" ]]; then
  echo "Error: PR_NUMBER is required" >&2
  exit 2
fi

pr_json="$(gh pr view "$pr_number" --json number,url,headRefOid,autoMergeRequest)"
pr_url="$(jq -r '.url // empty' <<< "$pr_json")"
pr_head_after="$(jq -r '.headRefOid // empty' <<< "$pr_json")"

if [[ -n "$pr_head_before" && -n "$pr_head_after" && "$pr_head_after" == "$pr_head_before" ]]; then
  echo "Skipping auto-merge: no PR changes pushed for #$pr_number"
  exit 0
fi

if [[ -z "$pr_url" ]]; then
  echo "Error: could not resolve PR URL for PR #$pr_number" >&2
  exit 1
fi

if jq -e '.autoMergeRequest != null' <<< "$pr_json" >/dev/null; then
  echo "Auto-merge already enabled for $pr_url"
  exit 0
fi

echo "Enabling auto-merge for PR #$pr_number ($pr_url)"
gh pr merge --auto --squash "$pr_url"
