#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/.github/scripts/enable-auto-merge.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$GH_CALLS"

if [[ "$1 $2 $3" == "pr view 42" ]]; then
  cat <<JSON
{"number":42,"url":"https://github.com/RiddimSoftware/app/pull/42","headRefOid":"$GH_HEAD_OID","autoMergeRequest":$GH_AUTO_MERGE}
JSON
  exit 0
fi

if [[ "$1 $2 $3" == "pr merge --auto" && "$4" == "--squash" ]]; then
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 64
GH
chmod +x "$TEST_DIR/bin/gh"

export PATH="$TEST_DIR/bin:$PATH"
export GH_CALLS="$TEST_DIR/gh-calls"

run_script() {
  : > "$GH_CALLS"
  "$SCRIPT" >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr"
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

assert_output_contains() {
  local name="$1"
  local expected="$2"
  if ! grep -Fq "$expected" "$TEST_DIR/stdout"; then
    echo "not ok - $name: expected '$expected'" >&2
    cat "$TEST_DIR/stdout" >&2 || true
    exit 1
  fi
  echo "ok - $name"
}

assert_calls_contain() {
  local name="$1"
  local expected="$2"
  if ! grep -Fq "$expected" "$GH_CALLS"; then
    echo "not ok - $name: expected gh call '$expected'" >&2
    cat "$GH_CALLS" >&2 || true
    exit 1
  fi
  echo "ok - $name"
}

export TRIGGER_TYPE=pr-fixup
export PR_NUMBER=42
export PR_HEAD_BEFORE=before
export GH_HEAD_OID=after
export GH_AUTO_MERGE=null
assert_success "pr-fixup enables auto-merge after push" run_script
assert_calls_contain "pr-fixup views pr number" "pr view 42 --json number,url,headRefOid,autoMergeRequest"
assert_calls_contain "pr-fixup runs gh pr merge" "pr merge --auto --squash https://github.com/RiddimSoftware/app/pull/42"

export TRIGGER_TYPE=pr-fixup
export PR_NUMBER=42
export PR_HEAD_BEFORE=same
export GH_HEAD_OID=same
export GH_AUTO_MERGE=null
assert_success "pr-fixup skips when head unchanged" run_script
assert_output_contains "pr-fixup skip message" "Skipping auto-merge: no PR changes pushed for pr-fixup #42"
if grep -Fq "pr merge --auto --squash" "$GH_CALLS"; then
  echo "not ok - pr-fixup unchanged did not merge" >&2
  cat "$GH_CALLS" >&2
  exit 1
fi
echo "ok - pr-fixup unchanged did not merge"

export TRIGGER_TYPE=changes_requested
export PR_NUMBER=42
export PR_HEAD_BEFORE=before
export GH_HEAD_OID=after
export GH_AUTO_MERGE=null
assert_success "changes_requested enables auto-merge using new trigger alias" run_script
assert_calls_contain "changes_requested views pr number" "pr view 42 --json number,url,headRefOid,autoMergeRequest"

export TRIGGER_TYPE=changes_requested
export PR_NUMBER=42
unset PR_HEAD_BEFORE || true
export GH_AUTO_MERGE='{"enabledBy":{"login":"developer-bot"}}'
assert_success "already-enabled auto-merge is idempotent" run_script
assert_output_contains "already-enabled message" "Auto-merge already enabled for https://github.com/RiddimSoftware/app/pull/42"
if grep -Fq "pr merge --auto --squash" "$GH_CALLS"; then
  echo "not ok - already-enabled did not merge again" >&2
  cat "$GH_CALLS" >&2
  exit 1
fi
echo "ok - already-enabled did not merge again"
