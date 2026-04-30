#!/usr/bin/env bash
# Checks a pull request diff before an agent reviewer runs.
#
# Usage: guard.sh [<pr-number>] [repo]
#   pr-number  Pull request number to inspect. May also be supplied via $PR_NUMBER env var.
#   repo       Optional. Defaults to $GITHUB_REPOSITORY.
#
# Environment variables (all optional):
#   PR_NUMBER             Pull request number (alternative to positional arg).
#   GUARD_MAX_LINES       Max allowed changed lines (additions + deletions). Default: 1000.
#   GUARD_MAX_FILES       Max allowed changed files. Default: 30.
#   GUARD_MAX_ATTEMPTS    Max automated attempt cycles before cap-hit block. Default: 3.
#   GUARD_SENSITIVE_PATHS Colon-separated additional sensitive path globs to block.
#                         These extend the built-in list below.
#
# Legacy alias (still accepted for backward compatibility):
#   MAX_DIFF_LINES        Alias for GUARD_MAX_LINES.
#
# Exit codes:
#   0  Guard passed — safe to proceed.
#   1  Guard blocked — reason printed to stdout; PR labeled agent:needs-human.
#   2  Usage error.
#
# On block the script also:
#   - Labels the PR with agent:needs-human.
#   - Posts a PR comment explaining the block reason.

set -euo pipefail

# ---------------------------------------------------------------------------
# Args + defaults
# ---------------------------------------------------------------------------

usage() {
  echo "Usage: $0 [<pull-request-number>] [repo]" >&2
  echo "  PR number may also be set via \$PR_NUMBER env var." >&2
}

# Accept PR number from env var or positional arg
if [[ $# -ge 1 && "$1" =~ ^[0-9]+$ ]]; then
  PR_NUMBER="$1"
  shift
elif [[ -n "${PR_NUMBER:-}" ]]; then
  : # already set via env
else
  usage
  exit 2
fi

if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: pull-request-number must be a positive integer, got: $PR_NUMBER" >&2
  exit 2
fi

REPO="${1:-${GITHUB_REPOSITORY:-}}"
REPO_FLAG=""
if [[ -n "$REPO" ]]; then
  REPO_FLAG="--repo $REPO"
fi

# GUARD_MAX_LINES is the canonical name; MAX_DIFF_LINES is a legacy alias.
GUARD_MAX_LINES="${GUARD_MAX_LINES:-${MAX_DIFF_LINES:-1000}}"
GUARD_MAX_FILES="${GUARD_MAX_FILES:-30}"
GUARD_MAX_ATTEMPTS="${GUARD_MAX_ATTEMPTS:-3}"

# ---------------------------------------------------------------------------
# Helper: post block actions (label + comment)
# ---------------------------------------------------------------------------

block() {
  local reason="$1"
  echo "Guard blocked: $reason"
  # shellcheck disable=SC2086
  gh pr edit "$PR_NUMBER" $REPO_FLAG --add-label "agent:needs-human" 2>/dev/null || true
  # shellcheck disable=SC2086
  gh pr comment "$PR_NUMBER" $REPO_FLAG --body "**Guard blocked this PR from automated review.**

Reason: $reason

A human must inspect the PR before automation resumes. To re-enable automation, resolve the issue and remove the \`agent:needs-human\` label." 2>/dev/null || true
  exit 1
}

# ---------------------------------------------------------------------------
# Kill-switch checks (must be first — before any expensive operations)
# ---------------------------------------------------------------------------

# shellcheck disable=SC2086
pr_labels="$(gh pr view "$PR_NUMBER" $REPO_FLAG --json labels --jq '[.labels[].name] | join(",")')"

if echo "$pr_labels" | grep -qF "agent:pause"; then
  block "PR has label 'agent:pause' (kill switch active)"
fi

attempt_cap_hit=false
for n in $(seq 1 99); do
  if echo "$pr_labels" | grep -qF "agent:attempt-${n}"; then
    if (( n >= GUARD_MAX_ATTEMPTS )); then
      attempt_cap_hit=true
      break
    fi
  fi
done
if [[ "$attempt_cap_hit" == "true" ]]; then
  block "PR attempt cap hit (max ${GUARD_MAX_ATTEMPTS} automated attempts reached)"
fi

if echo "$pr_labels" | grep -qF "agent:needs-human"; then
  block "PR already has label 'agent:needs-human'"
fi

# ---------------------------------------------------------------------------
# Diff size checks
# ---------------------------------------------------------------------------

# shellcheck disable=SC2086
changed_files="$(gh pr diff --name-only "$PR_NUMBER" $REPO_FLAG)"
# shellcheck disable=SC2086
diff_stat="$(gh pr diff --stat "$PR_NUMBER" $REPO_FLAG)"

changed_file_count() {
  sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]'
}

changed_line_count_from_stat() {
  awk '
    /changed/ {
      total = 0
      fields = split($0, parts, ",")
      for (i = 1; i <= fields; i++) {
        if (parts[i] ~ /insertion|deletion/) {
          match(parts[i], /[0-9]+/)
          if (RSTART > 0) {
            total += substr(parts[i], RSTART, RLENGTH)
          }
        }
      }
      print total
      found = 1
    }
    END {
      if (!found) {
        print 0
      }
    }
  '
}

file_count="$(printf '%s\n' "$changed_files" | changed_file_count)"
line_count="$(printf '%s\n' "$diff_stat" | changed_line_count_from_stat)"

if (( file_count > GUARD_MAX_FILES )); then
  block "Diff exceeds file threshold: ${file_count} files changed (cap: ${GUARD_MAX_FILES})"
fi

if (( line_count > GUARD_MAX_LINES )); then
  block "Diff exceeds line threshold: ${line_count} changed lines (cap: ${GUARD_MAX_LINES})"
fi

# ---------------------------------------------------------------------------
# Sensitive path checks
# ---------------------------------------------------------------------------

# Built-in sensitive globs (newline-separated)
DEFAULT_SENSITIVE_GLOBS="$(cat <<'GLOBS'
.github/workflows/**
.github/scripts/**
CODEOWNERS
scripts/setup-*
migrations/**
**/auth/**
infra/**
**/*.pem
**/*.key
fastlane/**
**/*Secrets*
**/Info.plist
**/*.entitlements
**/*.xcconfig
GLOBS
)"

# Convert colon-separated GUARD_SENSITIVE_PATHS to newline-separated
EXTRA_GLOBS=""
if [[ -n "${GUARD_SENSITIVE_PATHS:-}" ]]; then
  EXTRA_GLOBS="$(echo "$GUARD_SENSITIVE_PATHS" | tr ':' '\n')"
fi

glob_matches() {
  local path="$1"
  local pattern="$2"
  local without_prefix segment remainder

  [[ -n "$pattern" ]] || return 1

  # Enable extended globbing for ** support.
  shopt -s globstar extglob 2>/dev/null || true

  # Direct bash glob match (handles simple patterns like *.pem, fastlane/*).
  # shellcheck disable=SC2053
  [[ "$path" == $pattern ]] && return 0

  # Handle ** prefix: strip **/  and match the remainder against any path suffix.
  # e.g. "**/auth/**" should match "src/auth/login.js" and "auth/login.js".
  if [[ "$pattern" == \*\*/* ]]; then
    without_prefix="${pattern#\*\*/}"
    # Direct match of the remainder against the full path.
    # shellcheck disable=SC2053
    [[ "$path" == $without_prefix ]] && return 0
    # Also try matching the remainder against every path suffix (handle nested dirs).
    remainder="$path"
    while [[ "$remainder" == */* ]]; do
      remainder="${remainder#*/}"
      # shellcheck disable=SC2053
      [[ "$remainder" == $without_prefix ]] && return 0
    done
  fi

  return 1
}

while IFS= read -r fpath; do
  [[ -n "$fpath" ]] || continue

  while IFS= read -r glob; do
    [[ -n "$glob" ]] || continue
    if glob_matches "$fpath" "$glob"; then
      block "Sensitive path matched: ${fpath} (matched glob: ${glob})"
    fi
  done <<GLOBS
$DEFAULT_SENSITIVE_GLOBS
$EXTRA_GLOBS
GLOBS
done <<FILES
$changed_files
FILES

# ---------------------------------------------------------------------------
# All checks passed
# ---------------------------------------------------------------------------

echo "Guard passed. Stats: ${file_count} files changed, ${line_count} lines changed."
exit 0
