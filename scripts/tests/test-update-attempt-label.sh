#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/.github/scripts/update-attempt-label.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

state_file="$tmpdir/state"
log_file="$tmpdir/gh.log"
mock_bin="$tmpdir/bin"
mkdir -p "$mock_bin"

cat > "$mock_bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail

state_file="${GH_MOCK_STATE:?}"
log_file="${GH_MOCK_LOG:?}"
cmd="${1:-}"
shift || true

labels="$(sed -n 's/^labels=//p' "$state_file")"
comments="$(sed -n 's/^comments=//p' "$state_file")"

write_state() {
  {
    echo "labels=$labels"
    echo "comments=$comments"
  } > "$state_file"
}

case "$cmd" in
  pr)
    sub="${1:-}"
    shift || true
    case "$sub" in
      view)
        args="$*"
        if [[ "$args" == *"--json labels"* ]]; then
          tr ',' '\n' <<< "$labels" | sed '/^$/d'
        elif [[ "$args" == *"--json reviews"* ]]; then
          echo "review:riddim-reviewer-bot:2026-04-30T00:00:00Z"
        else
          echo "unsupported pr view: $args" >&2
          exit 2
        fi
        ;;
      edit)
        action=""
        label=""
        while [[ "$#" -gt 0 ]]; do
          case "$1" in
            --add-label|--remove-label)
              action="$1"
              label="${2:-}"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        echo "edit $action $label" >> "$log_file"
        case "$action" in
          --add-label)
            if ! tr ',' '\n' <<< "$labels" | grep -Fxq "$label"; then
              labels="${labels:+$labels,}$label"
            fi
            ;;
          --remove-label)
            labels="$(tr ',' '\n' <<< "$labels" | grep -Fvx "$label" | paste -sd, -)"
            ;;
          *)
            echo "unsupported pr edit: $*" >&2
            exit 2
            ;;
        esac
        write_state
        ;;
      comment)
        body="${5:-}"
        echo "comment $body" >> "$log_file"
        comments="${comments:+$comments|}$body"
        write_state
        ;;
      *)
        echo "unsupported pr subcommand: $sub" >&2
        exit 2
        ;;
    esac
    ;;
  api)
    tr '|' '\n' <<< "$comments" | sed '/^$/d'
    ;;
  *)
    echo "unsupported gh command: $cmd" >&2
    exit 2
    ;;
esac
MOCK_GH
chmod +x "$mock_bin/gh"

run_counter() {
  PATH="$mock_bin:$PATH" \
    GH_MOCK_STATE="$state_file" \
    GH_MOCK_LOG="$log_file" \
    REPO="RiddimSoftware/riddim-release" \
    "$script" "$@"
}

assert_labels() {
  local expected="$1"
  local actual
  actual="$(sed -n 's/^labels=//p' "$state_file")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected labels '$expected', got '$actual'." >&2
    exit 1
  fi
}

assert_log_count() {
  local pattern="$1"
  local expected="$2"
  local actual
  actual="$(grep -c "$pattern" "$log_file" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected $expected log lines matching '$pattern', got $actual." >&2
    exit 1
  fi
}

echo "labels=agent:attempt-2,automate" > "$state_file"
echo "comments=" >> "$state_file"
: > "$log_file"

run_counter fixup 123 >/dev/null
assert_labels "automate,agent:attempt-3"
assert_log_count "edit --add-label agent:attempt-3" 1
assert_log_count "edit --remove-label agent:attempt-2" 1
assert_log_count "comment <!-- agent-attempt-counter: source=review:riddim-reviewer-bot:2026-04-30T00:00:00Z; attempt=3 -->" 1

run_counter fixup 123 >/dev/null
assert_labels "automate,agent:attempt-3"
assert_log_count "edit --add-label agent:attempt-3" 2
assert_log_count "agent:attempt-4" 0

run_counter initial 123 >/dev/null
assert_labels "automate,agent:attempt-1"

echo "update_attempt_label tests passed."
