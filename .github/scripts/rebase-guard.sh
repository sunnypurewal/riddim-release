#!/usr/bin/env bash
# Guard and attempt-counter helper for stale autonomous PR rebases.
#
# Usage:
#   rebase-guard.sh <pr-number> [repo]
#
# Environment:
#   REBASE_MAX_ATTEMPTS        Default: 3
#   REBASE_MAX_FILES           Default: 8
#   REBASE_MAX_LINES           Default: 200
#   REBASE_INCREMENT_ATTEMPT   When "true", add the next agent:rebase-attempt-N label.
#   REBASE_BOT_OWNER_RE        Owners matching this regex do not veto CODEOWNERS.
#                              Default matches developer-bot / reviewer-bot with optional org, @, and [bot].
#
# Output:
#   First line is one of: ok, attempt-cap-exceeded, size-cap-exceeded, codeowners-veto.
#   Second line is compact JSON describing the decision.

set -euo pipefail

usage() {
  echo "Usage: $0 <pull-request-number> [repo]" >&2
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

emit() {
  local decision="$1"
  local reason="$2"
  local files_json="$3"
  printf '%s\n' "$decision"
  printf '{"decision":"%s","reason":%s,"files":%s,"conflicting_files":%s,"conflict_marker_lines":%s,"current_attempt":%s,"max_attempts":%s}\n' \
    "$decision" \
    "$(printf '%s' "$reason" | json_escape)" \
    "$files_json" \
    "$conflicting_file_count" \
    "$conflict_marker_lines" \
    "$current_attempt" \
    "$REBASE_MAX_ATTEMPTS"
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
if [[ -z "$REPO" ]]; then
  echo "Error: repo is required as argument or GITHUB_REPOSITORY." >&2
  exit 2
fi

REBASE_MAX_ATTEMPTS="${REBASE_MAX_ATTEMPTS:-3}"
REBASE_MAX_FILES="${REBASE_MAX_FILES:-8}"
REBASE_MAX_LINES="${REBASE_MAX_LINES:-200}"
REBASE_BOT_OWNER_RE="${REBASE_BOT_OWNER_RE:-(^|[/@])([^[:space:]/]*-)?(developer|reviewer)-bot(\\[bot\\])?$}"

labels="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json labels --jq '.labels[].name' 2>/dev/null || true)"

current_attempt=0
while IFS= read -r label; do
  case "$label" in
    agent:rebase-attempt-*)
      n="${label#agent:rebase-attempt-}"
      if [[ "$n" =~ ^[0-9]+$ ]] && (( n > current_attempt )); then
        current_attempt="$n"
      fi
      ;;
  esac
done <<< "$labels"

conflicting_files="$(git diff --name-only --diff-filter=U 2>/dev/null || true)"
marker_files="$(git grep -IlE '^(<<<<<<<|=======|>>>>>>>)' -- . 2>/dev/null || true)"
conflicting_files="$(printf '%s\n%s\n' "$conflicting_files" "$marker_files" | sed '/^$/d' | sort -u)"
conflicting_file_count="$(printf '%s\n' "$conflicting_files" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
conflict_marker_lines=0

if [[ -n "$conflicting_files" ]]; then
  while IFS= read -r file; do
    [[ -n "$file" && -f "$file" ]] || continue
    markers="$(grep -Ec '^(<<<<<<<|=======|>>>>>>>)' "$file" || true)"
    conflict_marker_lines=$((conflict_marker_lines + markers))
  done <<< "$conflicting_files"
fi

files_json="$(printf '%s\n' "$conflicting_files" | sed '/^$/d' | python3 -c 'import json,sys; print(json.dumps([l.rstrip("\n") for l in sys.stdin if l.strip()]))')"

post_guard_comment() {
  local marker="$1"
  local body="$2"
  local existing
  existing="$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" --jq ".[] | select(.body | contains(\"${marker}\")) | .id" 2>/dev/null | tail -n 1 || true)"

  if [[ -n "$existing" ]]; then
    gh api "repos/${REPO}/issues/comments/${existing}" --method PATCH -f "body=${body}" >/dev/null || true
  else
    gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$body" >/dev/null || true
  fi
}

label_needs_human() {
  gh pr edit "$PR_NUMBER" --repo "$REPO" --add-label "agent:needs-human" >/dev/null 2>&1 || true
}

if (( current_attempt >= REBASE_MAX_ATTEMPTS )); then
  reason="Rebase attempt cap reached: agent:rebase-attempt-${current_attempt} (cap: ${REBASE_MAX_ATTEMPTS})."
  label_needs_human
  post_guard_comment "<!-- riddim:rebase-guard:attempts -->" "<!-- riddim:rebase-guard:attempts -->
Automated rebase guard stopped this PR.

Reason: ${reason}

Remove \`agent:needs-human\` and the \`agent:rebase-attempt-*\` labels only after a human has inspected the PR."
  emit "attempt-cap-exceeded" "$reason" "$files_json"
  exit 0
fi

if [[ "${REBASE_INCREMENT_ATTEMPT:-false}" == "true" ]]; then
  next_attempt=$((current_attempt + 1))
  old_label="agent:rebase-attempt-${current_attempt}"
  new_label="agent:rebase-attempt-${next_attempt}"
  if (( current_attempt > 0 )); then
    gh pr edit "$PR_NUMBER" --repo "$REPO" --remove-label "$old_label" >/dev/null 2>&1 || true
  fi
  gh pr edit "$PR_NUMBER" --repo "$REPO" --add-label "$new_label" >/dev/null
  current_attempt="$next_attempt"
fi

if (( conflicting_file_count > REBASE_MAX_FILES || conflict_marker_lines > REBASE_MAX_LINES )); then
  reason="Conflict surface exceeds cap: ${conflicting_file_count} files / ${conflict_marker_lines} marker lines (caps: ${REBASE_MAX_FILES} files / ${REBASE_MAX_LINES} marker lines)."
  label_needs_human
  post_guard_comment "<!-- riddim:rebase-guard:size -->" "<!-- riddim:rebase-guard:size -->
Automated rebase guard stopped this PR.

Reason: ${reason}

Conflicting files:
\`\`\`
${conflicting_files}
\`\`\`"
  emit "size-cap-exceeded" "$reason" "$files_json"
  exit 0
fi

codeowners_file=""
for candidate in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
  if [[ -f "$candidate" ]]; then
    codeowners_file="$candidate"
    break
  fi
done

veto_lines=""
if [[ -n "$codeowners_file" && -n "$conflicting_files" ]]; then
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    match_line="$(python3 - "$codeowners_file" "$file" <<'PY'
import fnmatch
import sys

codeowners, path = sys.argv[1], sys.argv[2]
matched = ""
with open(codeowners, encoding="utf-8") as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        pattern, owners = parts[0], parts[1:]
        normalized = pattern.lstrip("/")
        candidates = [normalized]
        if normalized.endswith("/"):
            candidates.append(normalized + "**")
        if not normalized.startswith("**/"):
            candidates.append("**/" + normalized)
        if any(fnmatch.fnmatch(path, candidate) for candidate in candidates):
            matched = " ".join(owners)
print(matched)
PY
)"
    [[ -n "$match_line" ]] || continue
    bot_owned=true
    for owner in $match_line; do
      if ! [[ "$owner" =~ $REBASE_BOT_OWNER_RE ]]; then
        bot_owned=false
      fi
    done
    if [[ "$bot_owned" != "true" ]]; then
      veto_lines="${veto_lines}${file}: ${match_line}"$'\n'
    fi
  done <<< "$conflicting_files"
fi

if [[ -n "$veto_lines" ]]; then
  reason="Conflicts touch CODEOWNERS-protected paths that are not bot-owned."
  label_needs_human
  gh pr edit "$PR_NUMBER" --repo "$REPO" --add-label "agent:codeowners-veto" >/dev/null 2>&1 || true
  post_guard_comment "<!-- riddim:rebase-guard:codeowners -->" "<!-- riddim:rebase-guard:codeowners -->
Automated rebase guard stopped this PR.

Reason: ${reason}

Protected conflicts:
\`\`\`
${veto_lines}
\`\`\`"
  emit "codeowners-veto" "$reason" "$(printf '%s\n' "$veto_lines" | sed '/^$/d' | cut -d: -f1 | python3 -c 'import json,sys; print(json.dumps([l.rstrip("\n") for l in sys.stdin if l.strip()]))')"
  exit 0
fi

emit "ok" "Rebase guard passed." "$files_json"
exit 0
