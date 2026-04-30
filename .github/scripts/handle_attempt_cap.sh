#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  handle_attempt_cap.sh <pr-number>

Environment:
  REPO                  owner/repo for gh commands. Defaults to GITHUB_REPOSITORY.
  GH_TOKEN              token with pull-request label/comment/merge permissions.
  AGENT_ATTEMPT_CAP     maximum allowed fix-up attempts. Defaults to 3.
  AGENT_FALLBACK_OWNER  GitHub user or team mention used when CODEOWNERS lookup fails.
  AGENT_CODEOWNERS_PATH representative path for CODEOWNERS lookup. Defaults to README.md.
USAGE
}

pr_number="${1:-}"
if [[ -z "$pr_number" ]]; then
  usage
  exit 64
fi

repo="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$repo" ]]; then
  echo "REPO or GITHUB_REPOSITORY must be set." >&2
  exit 64
fi

attempt_cap="${AGENT_ATTEMPT_CAP:-3}"
if ! [[ "$attempt_cap" =~ ^[0-9]+$ ]] || (( attempt_cap < 1 )); then
  echo "AGENT_ATTEMPT_CAP must be a positive integer." >&2
  exit 64
fi

label_prefix="agent:attempt-"
needs_human_label="agent:needs-human"
fallback_owner="${AGENT_FALLBACK_OWNER:-SunnyPurewal}"
codeowners_path="${AGENT_CODEOWNERS_PATH:-README.md}"

write_output() {
  local name="$1"
  local value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "${name}=${value}" >> "$GITHUB_OUTPUT"
  fi
}

normalize_mention() {
  local raw="$1"
  raw="${raw#@}"
  if [[ -z "$raw" ]]; then
    raw="${fallback_owner#@}"
  fi
  echo "@${raw}"
}

current_attempt() {
  gh pr view "$pr_number" --repo "$repo" --json labels --jq '.labels[].name' |
    sed -n "s/^${label_prefix}\([0-9][0-9]*\)$/\1/p" |
    sort -n |
    tail -n 1
}

resolve_owner() {
  local owner
  owner="$(gh api "repos/${repo}/codeowners/${codeowners_path}" \
    --jq '.owners[0].login // .owners[0].name // .codeowners[0].login // .codeowners[0].name // .[0].login // .[0].name // empty' 2>/dev/null || true)"

  if [[ -z "$owner" ]]; then
    owner="$fallback_owner"
  fi

  normalize_mention "$owner"
}

last_review_feedback() {
  local feedback
  feedback="$(gh pr view "$pr_number" --repo "$repo" --json reviews \
    --jq '[.reviews[] | select(.state == "CHANGES_REQUESTED")] | last | .body // ""' 2>/dev/null || true)"
  feedback="${feedback//$'\r'/ }"
  feedback="${feedback//$'\n'/ }"
  feedback="${feedback:0:500}"

  if [[ -z "$feedback" ]]; then
    echo "No changes-requested review body was available."
  else
    echo "$feedback"
  fi
}

last_commit_sha() {
  local sha
  sha="$(gh pr view "$pr_number" --repo "$repo" --json commits \
    --jq '.commits[-1].oid // empty' 2>/dev/null || true)"

  if [[ -z "$sha" ]]; then
    sha="${GITHUB_SHA:-unknown}"
  fi

  echo "$sha"
}

logs_url() {
  if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
    echo "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
  else
    echo "Unavailable in local execution."
  fi
}

attempt="$(current_attempt)"
if [[ -z "$attempt" ]]; then
  attempt=0
fi

write_output "attempt" "$attempt"

if (( attempt <= attempt_cap )); then
  write_output "cap_hit" "false"
  echo "Attempt ${attempt} is within cap ${attempt_cap}; continuing."
  exit 0
fi

mention="$(resolve_owner)"
feedback="$(last_review_feedback)"
sha="$(last_commit_sha)"
run_url="$(logs_url)"

gh pr edit "$pr_number" --repo "$repo" --add-label "$needs_human_label"
gh pr merge --disable-auto "$pr_number" --repo "$repo" 2>/dev/null || true
gh pr comment "$pr_number" --repo "$repo" --body "$(cat <<COMMENT
${mention} agent attempt cap hit for PR #${pr_number}.

- Attempts made: ${attempt} (cap ${attempt_cap})
- Last reviewer feedback: ${feedback}
- Last commit SHA: ${sha}
- Logs: ${run_url}

Added \`${needs_human_label}\` and disabled auto-merge. The developer agent was not invoked.
COMMENT
)"

write_output "cap_hit" "true"
echo "Attempt ${attempt} exceeds cap ${attempt_cap}; marked PR as needing human review."
