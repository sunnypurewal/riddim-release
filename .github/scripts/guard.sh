#!/usr/bin/env bash
# Checks a pull request diff before an agent reviewer runs.
#
# Defaults:
#   GUARD_MAX_FILES=30
#   GUARD_MAX_LINES=1000
#   GUARD_SENSITIVE_GLOBS appends newline-separated globs to the defaults below.
#
# The script only reads diff paths and stats. On failure it prints one safe,
# single-line reason suitable for a public PR comment.

set -euo pipefail

usage() {
  echo "Usage: $0 <pull-request-number>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

PR_NUMBER="$1"
GUARD_MAX_FILES="${GUARD_MAX_FILES:-30}"
GUARD_MAX_LINES="${GUARD_MAX_LINES:-1000}"

DEFAULT_SENSITIVE_GLOBS="$(cat <<'GLOBS'
migrations/**
**/auth/**
.github/**
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

changed_files="$(gh pr diff --name-only "$PR_NUMBER")"
diff_stat="$(gh pr diff --stat "$PR_NUMBER")"

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

glob_matches() {
  local path="$1"
  local pattern="$2"
  local without_prefix

  [[ -n "$pattern" ]] || return 1
  # shellcheck disable=SC2053 # Right-hand side is intentionally a glob pattern.
  [[ "$path" == $pattern ]] && return 0

  if [[ "$pattern" == \*\*/* ]]; then
    without_prefix="${pattern#\*\*/}"
    # shellcheck disable=SC2053 # Right-hand side is intentionally a glob pattern.
    [[ "$path" == $without_prefix ]] && return 0
  fi

  return 1
}

file_count="$(printf '%s\n' "$changed_files" | changed_file_count)"
line_count="$(printf '%s\n' "$diff_stat" | changed_line_count_from_stat)"

if (( file_count > GUARD_MAX_FILES )); then
  echo "Diff exceeds size threshold: ${file_count} files (cap ${GUARD_MAX_FILES})"
  exit 1
fi

if (( line_count > GUARD_MAX_LINES )); then
  echo "Diff exceeds size threshold: ${line_count} changed lines (cap ${GUARD_MAX_LINES})"
  exit 1
fi

while IFS= read -r path; do
  [[ -n "$path" ]] || continue

  while IFS= read -r glob; do
    [[ -n "$glob" ]] || continue
    if glob_matches "$path" "$glob"; then
      echo "Sensitive path matched: ${path}"
      exit 1
    fi
  done <<GLOBS
$DEFAULT_SENSITIVE_GLOBS
${GUARD_SENSITIVE_GLOBS:-}
GLOBS
done <<FILES
$changed_files
FILES

exit 0
