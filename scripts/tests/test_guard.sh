#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/.github/scripts/guard.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1 $2 $3" != "pr diff --name-only" && "$1 $2 $3" != "pr diff --stat" ]]; then
  echo "unexpected gh invocation: $*" >&2
  exit 64
fi

case "$3" in
  --name-only) printf '%s\n' "$GUARD_TEST_NAME_ONLY" ;;
  --stat) printf '%s\n' "$GUARD_TEST_STAT" ;;
esac
GH
chmod +x "$TEST_DIR/bin/gh"

export PATH="$TEST_DIR/bin:$PATH"

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
    echo "not ok - $name: expected failure" >&2
    exit 1
  fi

  if ! grep -Fq "$expected" "$TEST_DIR/stdout"; then
    echo "not ok - $name: expected '$expected'" >&2
    cat "$TEST_DIR/stdout" >&2 || true
    cat "$TEST_DIR/stderr" >&2 || true
    exit 1
  fi

  echo "ok - $name"
}

export GUARD_TEST_NAME_ONLY=$'README.md\nscripts/release/compute_next_version.py'
export GUARD_TEST_STAT=$' README.md                             | 2 +-\n scripts/release/compute_next_version.py | 4 ++--\n 2 files changed, 3 insertions(+), 3 deletions(-)'
assert_success "safe diff exits 0" run_guard

export GUARD_MAX_FILES=1
assert_failure_contains \
  "oversize diff exits 1" \
  "Diff exceeds size threshold: 2 files (cap 1)" \
  run_guard
unset GUARD_MAX_FILES

export GUARD_TEST_NAME_ONLY=$'fastlane/Fastfile\nREADME.md'
export GUARD_TEST_STAT=$' fastlane/Fastfile | 1 +\n README.md         | 1 +\n 2 files changed, 2 insertions(+)'
assert_failure_contains \
  "sensitive path exits 1" \
  "Sensitive path matched: fastlane/Fastfile" \
  run_guard

export GUARD_TEST_NAME_ONLY=$'README.md\nscripts/release/compute_next_version.py'
export GUARD_MAX_LINES=5
export GUARD_TEST_STAT=$' README.md                             | 3 ++-\n scripts/release/compute_next_version.py | 4 ++--\n 2 files changed, 6 insertions(+), 1 deletion(-)'
assert_failure_contains \
  "oversize line count exits 1" \
  "Diff exceeds size threshold: 7 changed lines (cap 5)" \
  run_guard
unset GUARD_MAX_LINES

export GUARD_TEST_NAME_ONLY=$'README.md\napp/internal/secrets/config.ts'
export GUARD_TEST_STAT=$' README.md                            | 1 +\n app/internal/secrets/config.ts        | 2 +-\n 2 files changed, 2 insertions(+), 1 deletion(-)'
export GUARD_SENSITIVE_GLOBS=$'**/*secrets*'
assert_failure_contains \
  "custom GUARD_SENSITIVE_GLOBS exits 1" \
  "Sensitive path matched: app/internal/secrets/config.ts" \
  run_guard
unset GUARD_SENSITIVE_GLOBS
