#!/usr/bin/env bash
# Self-test harness for .github/scripts/guard.sh
# Covers: safe diff → exit 0, oversize diff → exit 1, sensitive path → exit 1,
#         custom glob override, and kill-switch label checks.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/.github/scripts/guard.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# ---------------------------------------------------------------------------
# Mock gh binary
# Supports: pr view (labels), pr diff --name-only, pr diff --stat,
#           pr edit (add-label), pr comment
# ---------------------------------------------------------------------------
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

subcmd="$1 $2"   # e.g. "pr view" or "pr diff"

case "$subcmd" in
  "pr view")
    # Return label list for kill-switch checks.
    # Controlled by GUARD_TEST_LABELS (comma-separated), defaults to empty.
    labels="${GUARD_TEST_LABELS:-}"
    if [[ -n "$labels" ]]; then
      # Convert comma list to JSON-style joined string expected by jq output
      echo "$labels"
    else
      echo ""
    fi
    ;;
  "pr diff")
    case "$3" in
      --name-only) printf '%s\n' "${GUARD_TEST_NAME_ONLY:-}" ;;
      --stat)      printf '%s\n' "${GUARD_TEST_STAT:-}" ;;
      *) echo "unexpected pr diff flag: $3" >&2; exit 64 ;;
    esac
    ;;
  "pr edit"|"pr comment")
    # Side-effect calls — silently succeed in tests
    exit 0
    ;;
  *)
    echo "unexpected gh invocation: $*" >&2
    exit 64
    ;;
esac
GH
chmod +x "$TEST_DIR/bin/gh"

export PATH="$TEST_DIR/bin:$PATH"

# ---------------------------------------------------------------------------
# Test runner helpers
# ---------------------------------------------------------------------------
run_guard() {
  "$GUARD" 123 >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr"
}

assert_success() {
  local name="$1"
  shift
  if ! "$@"; then
    echo "not ok - $name" >&2
    cat "$TEST_DIR/stdout" >&2 || true
    cat "$TEST_DIR/stderr" >&2 || true
    exit 1
  fi
  echo "ok - $name"
}

assert_failure_contains() {
  local name="$1"
  local expected="$2"
  shift 2

  set +e
  "$@"
  local status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "not ok - $name: expected non-zero exit" >&2
    cat "$TEST_DIR/stdout" >&2 || true
    cat "$TEST_DIR/stderr" >&2 || true
    exit 1
  fi

  if ! grep -Fq "$expected" "$TEST_DIR/stdout"; then
    echo "not ok - $name: expected stdout to contain '$expected'" >&2
    cat "$TEST_DIR/stdout" >&2 || true
    cat "$TEST_DIR/stderr" >&2 || true
    exit 1
  fi

  echo "ok - $name"
}

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

# 1. Safe diff → exit 0
export GUARD_TEST_LABELS=""
export GUARD_TEST_NAME_ONLY=$'README.md\nscripts/release/compute_next_version.py'
export GUARD_TEST_STAT=$' README.md                             | 2 +-\n scripts/release/compute_next_version.py | 4 ++--\n 2 files changed, 3 insertions(+), 3 deletions(-)'
assert_success "safe diff exits 0" run_guard

# 2. Oversize file count → exit 1
export GUARD_MAX_FILES=1
assert_failure_contains \
  "oversize file count exits 1" \
  "Diff exceeds file threshold: 2 files changed (cap: 1)" \
  run_guard
unset GUARD_MAX_FILES

# 3. Sensitive path (fastlane) → exit 1
export GUARD_TEST_NAME_ONLY=$'fastlane/Fastfile\nREADME.md'
export GUARD_TEST_STAT=$' fastlane/Fastfile | 1 +\n README.md         | 1 +\n 2 files changed, 2 insertions(+)'
assert_failure_contains \
  "sensitive path exits 1" \
  "Sensitive path matched: fastlane/Fastfile" \
  run_guard

# 4. Oversize line count → exit 1
export GUARD_TEST_NAME_ONLY=$'README.md\nscripts/release/compute_next_version.py'
export MAX_DIFF_LINES=5
export GUARD_TEST_STAT=$' README.md                               | 4 ++++\n scripts/release/compute_next_version.py | 3 ++-\n 2 files changed, 6 insertions(+), 1 deletion(-)'
assert_failure_contains \
  "oversize line count exits 1" \
  "Diff exceeds line threshold: 7 changed lines (cap: 5)" \
  run_guard
unset MAX_DIFF_LINES

# 5. Custom GUARD_SENSITIVE_GLOBS env var
export GUARD_TEST_NAME_ONLY=$'README.md\napp/internal/secrets/config.ts'
export GUARD_TEST_STAT=$' README.md                            | 1 +\n app/internal/secrets/config.ts        | 2 +-\n 2 files changed, 2 insertions(+), 1 deletion(-)'
export GUARD_SENSITIVE_PATHS="**/*secrets*"
assert_failure_contains \
  "custom GUARD_SENSITIVE_PATHS exits 1" \
  "Sensitive path matched: app/internal/secrets/config.ts" \
  run_guard
unset GUARD_SENSITIVE_PATHS

# 6. Kill-switch: agent:pause label → exit 1
export GUARD_TEST_LABELS="agent:pause"
export GUARD_TEST_NAME_ONLY=$'README.md'
export GUARD_TEST_STAT=$' README.md | 1 +\n 1 file changed, 1 insertion(+)'
assert_failure_contains \
  "agent:pause label blocks guard" \
  "agent:pause" \
  run_guard
unset GUARD_TEST_LABELS

echo ""
echo "All guard tests passed."
