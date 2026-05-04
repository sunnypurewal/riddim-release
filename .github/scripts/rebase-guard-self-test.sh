#!/usr/bin/env bash
# Deterministic smoke coverage for rebase-guard local-only decisions.
# Networked label/comment writes are intentionally stubbed so this can run in CI
# or under act without mutating a real PR.

set -euo pipefail

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="${script_dir}/rebase-guard.sh"

mkdir -p "$tmpdir/bin" "$tmpdir/repo"
cat > "$tmpdir/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "pr view" ]]; then
  printf '%s\n' "${GH_LABELS:-}"
  exit 0
fi
if [[ "$1" == "pr" || "$1" == "api" ]]; then
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 1
GH
chmod +x "$tmpdir/bin/gh"

export PATH="$tmpdir/bin:$PATH"
export GITHUB_REPOSITORY="RiddimSoftware/example"

cd "$tmpdir/repo"
git init -q
git config user.email test@example.invalid
git config user.name "Rebase Guard Test"

run_guard() {
  GH_LABELS="${1:-}" "$guard" 1 "$GITHUB_REPOSITORY" | head -n 1
}

assert_decision() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL ${name}: expected ${expected}, got ${actual}" >&2
    exit 1
  fi
  echo "PASS ${name}: ${actual}"
}

assert_decision "attempt cap" "attempt-cap-exceeded" "$(run_guard "agent:rebase-attempt-3")"

cat > conflict.txt <<'TXT'
<<<<<<< HEAD
ours
=======
theirs
>>>>>>> main
TXT
git add conflict.txt
assert_decision "size cap" "size-cap-exceeded" "$(
  REBASE_MAX_FILES=0 run_guard ""
)"

mkdir -p .github
cat > .github/CODEOWNERS <<'OWNERS'
conflict.txt @human-team
OWNERS
assert_decision "codeowners veto" "codeowners-veto" "$(run_guard "")"

cat > .github/CODEOWNERS <<'OWNERS'
conflict.txt @riddim-reviewer-bot[bot]
OWNERS
assert_decision "bot-owned path" "ok" "$(run_guard "")"
