#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  update_attempt_label.sh initial <pr-number>
  update_attempt_label.sh fixup <pr-number>

Environment:
  REPO      owner/repo for gh commands. Defaults to GITHUB_REPOSITORY.
  GH_TOKEN  token with pull-request and issue label/comment permissions.
USAGE
}

mode="${1:-}"
pr_number="${2:-}"

if [[ -z "$mode" || -z "$pr_number" ]]; then
  usage
  exit 64
fi

repo="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$repo" ]]; then
  echo "REPO or GITHUB_REPOSITORY must be set." >&2
  exit 64
fi

label_prefix="agent:attempt-"
marker_prefix="<!-- agent-attempt-counter:"

attempt_labels() {
  gh pr view "$pr_number" --repo "$repo" --json labels --jq '.labels[].name' |
    grep -E "^${label_prefix}[0-9]+$" || true
}

max_attempt() {
  local max=0
  local label n
  while IFS= read -r label; do
    [[ -z "$label" ]] && continue
    n="${label#"${label_prefix}"}"
    if (( n > max )); then
      max="$n"
    fi
  done < <(attempt_labels)
  echo "$max"
}

remove_other_attempts() {
  local keep="$1"
  local label
  while IFS= read -r label; do
    [[ -z "$label" || "$label" == "$keep" ]] && continue
    gh pr edit "$pr_number" --repo "$repo" --remove-label "$label"
  done < <(attempt_labels)
}

ensure_single_attempt_label() {
  local target="$1"
  gh pr edit "$pr_number" --repo "$repo" --add-label "$target"
  remove_other_attempts "$target"
}

latest_review_source() {
  local source
  source="$(gh pr view "$pr_number" --repo "$repo" --json reviews \
    --jq '[.reviews[] | select(.state == "CHANGES_REQUESTED")] | last | if . == null then "" else "review:" + (.author.login // "unknown") + ":" + (.submittedAt // "unknown") end' 2>/dev/null || true)"

  if [[ -n "$source" ]]; then
    echo "$source"
  else
    echo "pr:${pr_number}:fixup"
  fi
}

marked_attempt_for_source() {
  local source="$1"
  gh api "repos/${repo}/issues/${pr_number}/comments" \
    --jq ".[] | select(.body | contains(\"${marker_prefix}\")) | select(.body | contains(\"source=${source};\")) | .body" 2>/dev/null |
    sed -n 's/.*attempt=\([0-9][0-9]*\).*/\1/p' |
    tail -n 1
}

post_marker() {
  local source="$1"
  local attempt="$2"
  gh pr comment "$pr_number" --repo "$repo" \
    --body "${marker_prefix} source=${source}; attempt=${attempt} -->"
}

verify_target() {
  local target="$1"
  local labels count
  labels="$(attempt_labels)"
  count="$(printf '%s\n' "$labels" | sed '/^$/d' | wc -l | tr -d ' ')"
  [[ "$count" == "1" ]] && [[ "$labels" == "$target" ]]
}

case "$mode" in
  initial)
    ensure_single_attempt_label "${label_prefix}1"
    echo "Attempt label set to ${label_prefix}1."
    ;;

  fixup)
    source="$(latest_review_source)"
    existing_attempt="$(marked_attempt_for_source "$source")"

    if [[ -n "$existing_attempt" ]]; then
      target="${label_prefix}${existing_attempt}"
      ensure_single_attempt_label "$target"
      echo "Attempt label already recorded for ${source}; kept ${target}."
      exit 0
    fi

    current="$(max_attempt)"
    target_number=$((current + 1))
    target="${label_prefix}${target_number}"
    post_marker "$source" "$target_number"

    ensure_single_attempt_label "$target"
    if verify_target "$target"; then
      echo "Attempt label advanced to ${target}."
      exit 0
    fi

    ensure_single_attempt_label "$target"
    if verify_target "$target"; then
      echo "Attempt label advanced to ${target}."
      exit 0
    fi

    echo "Failed to verify ${target} after retry." >&2
    exit 1
    ;;

  *)
    usage
    exit 64
    ;;
esac
