#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/.github/scripts/handle_attempt_cap.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

state_file="$test_dir/state"
log_file="$test_dir/gh.log"
mock_bin="$test_dir/bin"
mkdir -p "$mock_bin"

cat > "$mock_bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail

state_file="${GH_MOCK_STATE:?}"
log_file="${GH_MOCK_LOG:?}"
cmd="${1:-}"
shift || true

labels="$(sed -n 's/^labels=//p' "$state_file")"
codeowner="$(sed -n 's/^codeowner=//p' "$state_file")"
review="$(sed -n 's/^review=//p' "$state_file")"
sha="$(sed -n 's/^sha=//p' "$state_file")"

write_state() {
  {
    echo "labels=$labels"
    echo "codeowner=$codeowner"
    echo "review=$review"
    echo "sha=$sha"
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
          printf '%s\n' "$review"
        elif [[ "$args" == *"--json commits"* ]]; then
          printf '%s\n' "$sha"
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
        if [[ "$action" != "--add-label" ]]; then
          echo "unsupported pr edit: $*" >&2
          exit 2
        fi
        if ! tr ',' '\n' <<< "$labels" | grep -Fxq "$label"; then
          labels="${labels:+$labels,}$label"
        fi
        write_state
        ;;
      merge)
        echo "merge $*" >> "$log_file"
        ;;
      comment)
        body=""
        while [[ "$#" -gt 0 ]]; do
          case "$1" in
            --body)
              body="${2:-}"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        printf 'comment %s\n' "$body" >> "$log_file"
        ;;
      *)
        echo "unsupported pr subcommand: $sub" >&2
        exit 2
        ;;
    esac
    ;;
  api)
    if [[ -z "$codeowner" ]]; then
      exit 1
    fi
    printf '%s\n' "$codeowner"
    ;;
  *)
    echo "unsupported gh command: $cmd" >&2
    exit 2
    ;;
esac
MOCK_GH
chmod +x "$mock_bin/gh"

run_cap() {
  local output_file="$test_dir/output"
  : > "$output_file"
  PATH="$mock_bin:$PATH" \
    GH_MOCK_STATE="$state_file" \
    GH_MOCK_LOG="$log_file" \
    GITHUB_OUTPUT="$output_file" \
    GITHUB_SERVER_URL="https://github.com" \
    GITHUB_REPOSITORY="RiddimSoftware/riddim-release" \
    GITHUB_RUN_ID="4242" \
    REPO="RiddimSoftware/riddim-release" \
    AGENT_ATTEMPT_CAP="${AGENT_ATTEMPT_CAP:-3}" \
    AGENT_FALLBACK_OWNER="${AGENT_FALLBACK_OWNER:-SunnyPurewal}" \
    "$script" 123 >/dev/null
  cat "$output_file"
}

assert_contains() {
  local file="$1"
  local expected="$2"
  if ! grep -Fq "$expected" "$file"; then
    echo "Expected '$expected' in $file." >&2
    cat "$file" >&2 || true
    exit 1
  fi
}

cat > "$state_file" <<'STATE'
labels=agent:attempt-3,automate
codeowner=
review=Please fix the failing test.
sha=abc123
STATE
: > "$log_file"

run_cap > "$test_dir/output_lines"
assert_contains "$test_dir/output_lines" "cap_hit=false"
if [[ -s "$log_file" ]]; then
  echo "Expected no side effects while attempt is within cap." >&2
  cat "$log_file" >&2
  exit 1
fi

cat > "$state_file" <<'STATE'
labels=agent:attempt-4,automate
codeowner=octo-team
review=Please fix the failing test.
sha=def456
STATE
: > "$log_file"

run_cap > "$test_dir/output_lines"
assert_contains "$test_dir/output_lines" "cap_hit=true"
assert_contains "$log_file" "edit --add-label agent:needs-human"
assert_contains "$log_file" "merge --disable-auto 123 --repo RiddimSoftware/riddim-release"
assert_contains "$log_file" "@octo-team agent attempt cap hit"
assert_contains "$log_file" "Attempts made: 4 (cap 3)"
assert_contains "$log_file" "Last reviewer feedback: Please fix the failing test."
assert_contains "$log_file" "Last commit SHA: def456"
assert_contains "$log_file" "Logs: https://github.com/RiddimSoftware/riddim-release/actions/runs/4242"

cat > "$state_file" <<'STATE'
labels=agent:attempt-4
codeowner=
review=
sha=
STATE
: > "$log_file"

run_cap > "$test_dir/output_lines"
assert_contains "$log_file" "@SunnyPurewal agent attempt cap hit"
assert_contains "$log_file" "No changes-requested review body was available."

echo "handle_attempt_cap tests passed."
