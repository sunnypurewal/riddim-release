#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
extract_script="$repo_root/.github/scripts/extract-conflict-context.sh"
validate_script="$repo_root/.github/scripts/validate-conflict-resolution.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mock_bin="$tmpdir/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
  cat <<'JSON'
{"title":"RIDDIM-137 Test PR","body":"Implements RIDDIM-137 acceptance criteria.","url":"https://example.test/pr/1","headRefName":"feature","baseRefName":"main"}
JSON
  exit 0
fi
exit 0
MOCK_GH
chmod +x "$mock_bin/gh"

repo="$tmpdir/repo"
mkdir "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test

current_branch="$(git -C "$repo" branch --show-current)"
if [ "$current_branch" != "main" ]; then
  if git -C "$repo" show-ref --verify --quiet "refs/heads/main"; then
    git -C "$repo" checkout -q main
  else
    git -C "$repo" branch -m main
  fi
fi

cat > "$repo/file.txt" <<'BASE'
alpha
context
old line
omega
BASE
git -C "$repo" add file.txt
git -C "$repo" commit -q -m base
git -C "$repo" checkout -q -b feature
cat > "$repo/file.txt" <<'FEATURE'
alpha
context
feature line
omega
FEATURE
git -C "$repo" commit -am feature -q
git -C "$repo" checkout -q main
cat > "$repo/file.txt" <<'MAIN'
alpha
context
main line
omega
MAIN
git -C "$repo" commit -am main -q
git -C "$repo" checkout -q feature
set +e
git -C "$repo" rebase main >/dev/null 2>&1
set -e

(
  cd "$repo"
  PATH="$mock_bin:$PATH" "$extract_script" 1 RiddimSoftware/riddim-release main .agent-rebase >/tmp/extract.out
)

grep -F "file.txt" "$repo/.agent-rebase/conflicted-files.txt" >/dev/null
grep -F "Autonomous conflict-resolution context" "$repo/.agent-rebase/conflict-context.md" >/dev/null

cat > "$repo/file.txt" <<'RESOLVED'
alpha
context
feature line
main line
omega
RESOLVED
(
  cd "$repo"
  "$validate_script" .agent-rebase/conflicted-files.txt .agent-rebase/outside-snapshot.json >/tmp/validate.out
)
grep -F "validation passed" /tmp/validate.out >/dev/null

cat > "$repo/file.txt" <<'BROKEN'
alpha
inserted outside context
context
feature line
main line
omega
BROKEN
if (
  cd "$repo"
  "$validate_script" .agent-rebase/conflicted-files.txt .agent-rebase/outside-snapshot.json >/tmp/validate-bad.out 2>&1
); then
  echo "expected validation to fail when non-conflict context gains inserted lines" >&2
  exit 1
fi

echo "agent_rebase helper tests passed."
