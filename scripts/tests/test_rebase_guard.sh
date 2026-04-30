#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/.github/scripts/rebase-guard.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mock_bin="$tmpdir/bin"
mkdir -p "$mock_bin"

cat > "$mock_bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail

state="${GH_MOCK_STATE:?}"
labels="$(sed -n 's/^labels=//p' "$state")"

write_labels() {
  {
    echo "labels=$labels"
  } > "$state"
}

case "${1:-}" in
  pr)
    sub="${2:-}"
    shift 2 || true
    case "$sub" in
      view)
        tr ',' '\n' <<< "$labels" | sed '/^$/d'
        ;;
      edit)
        action=""
        label=""
        while [[ "$#" -gt 0 ]]; do
          case "$1" in
            --add-label|--remove-label)
              action="$1"
              label="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        case "$action" in
          --add-label)
            if ! tr ',' '\n' <<< "$labels" | grep -Fxq "$label"; then
              labels="${labels:+$labels,}$label"
            fi
            ;;
          --remove-label)
            labels="$(tr ',' '\n' <<< "$labels" | grep -Fvx "$label" | paste -sd, -)"
            ;;
        esac
        write_labels
        ;;
      comment)
        exit 0
        ;;
    esac
    ;;
  api)
    if [[ "$*" == *"--method PATCH"* ]]; then
      exit 0
    fi
    ;;
esac
MOCK_GH
chmod +x "$mock_bin/gh"

run_case() {
  local name="$1"
  local expected="$2"
  shift 2
  (
    cd "$tmpdir/repo"
    PATH="$mock_bin:$PATH" GH_MOCK_STATE="$tmpdir/state" "$script" 123 RiddimSoftware/riddim-release "$@"
  ) > "$tmpdir/out"
  if [[ "$(head -n 1 "$tmpdir/out")" != "$expected" ]]; then
    echo "not ok - $name" >&2
    cat "$tmpdir/out" >&2
    exit 1
  fi
  echo "ok - $name"
}

reset_repo() {
  rm -rf "$tmpdir/repo"
  mkdir "$tmpdir/repo"
  git -C "$tmpdir/repo" init -q
  git -C "$tmpdir/repo" config user.email test@example.com
  git -C "$tmpdir/repo" config user.name Test
  echo base > "$tmpdir/repo/file.txt"
  git -C "$tmpdir/repo" add file.txt
  git -C "$tmpdir/repo" commit -q -m base
}

echo "labels=" > "$tmpdir/state"
reset_repo
run_case "no conflicts passes" ok

echo "labels=agent:rebase-attempt-3" > "$tmpdir/state"
reset_repo
run_case "attempt cap blocks" attempt-cap-exceeded

echo "labels=" > "$tmpdir/state"
reset_repo
cat > "$tmpdir/repo/file.txt" <<'EOF'
<<<<<<< HEAD
ours
=======
theirs
>>>>>>> main
EOF
git -C "$tmpdir/repo" add file.txt
REBASE_MAX_LINES=2 run_case "marker cap blocks" size-cap-exceeded

echo "labels=" > "$tmpdir/state"
reset_repo
cat > "$tmpdir/repo/CODEOWNERS" <<'EOF'
file.txt @human-reviewer
EOF
cat > "$tmpdir/repo/file.txt" <<'EOF'
<<<<<<< HEAD
ours
=======
theirs
>>>>>>> main
EOF
git -C "$tmpdir/repo" add CODEOWNERS file.txt
run_case "codeowners veto blocks" codeowners-veto

echo "rebase_guard tests passed."
