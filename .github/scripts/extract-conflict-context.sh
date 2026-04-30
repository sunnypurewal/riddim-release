#!/usr/bin/env bash
# Build a bounded conflict-resolution dossier for agent-rebase.yml.
#
# Usage: extract-conflict-context.sh <pr-number> <repo> <base-branch> <output-dir>
#
# Outputs:
#   <output-dir>/conflict-context.md       Human-readable prompt context.
#   <output-dir>/conflicted-files.txt      Newline-separated conflicted files.
#   <output-dir>/outside-snapshot.json     Non-conflict line snapshot for validation.
#   /tmp/pre_resolution/<file>             Original conflicted file content copied for
#                                          downstream validation/safety checks.

set -euo pipefail

usage() {
  echo "Usage: $0 <pr-number> <repo> <base-branch> <output-dir>" >&2
}

if [[ $# -ne 4 ]]; then
  usage
  exit 2
fi

PR_NUMBER="$1"
REPO="$2"
BASE_BRANCH="$3"
OUT_DIR="$4"
PRE_RESOLUTION_DIR="/tmp/pre_resolution"

if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: pr-number must be a positive integer, got: $PR_NUMBER" >&2
  exit 2
fi

mkdir -p "$OUT_DIR"
CONTEXT_FILE="$OUT_DIR/conflict-context.md"
FILES_FILE="$OUT_DIR/conflicted-files.txt"
SNAPSHOT_FILE="$OUT_DIR/outside-snapshot.json"

conflicted_files="$(git diff --name-only --diff-filter=U | sed '/^$/d' | sort -u)"
printf '%s\n' "$conflicted_files" | sed '/^$/d' > "$FILES_FILE"

if [[ ! -s "$FILES_FILE" ]]; then
  echo "Error: no conflicted files detected." >&2
  exit 1
fi

pr_json="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json title,body,url,headRefName,baseRefName 2>/dev/null || printf '{}')"

jira_key="$(PR_JSON="$pr_json" python3 - <<'PY'
import json, os, re
try:
    data = json.loads(os.environ.get("PR_JSON") or "{}")
except Exception:
    data = {}
text = "\n".join(str(data.get(k) or "") for k in ("title", "body"))
match = re.search(r"\b[A-Z][A-Z0-9]+-\d+\b", text)
print(match.group(0) if match else "")
PY
)"

jira_context=""
if [[ -n "$jira_key" && -n "${ATLASSIAN_BASE_URL:-}" && -n "${ATLASSIAN_API_USER:-}" && -n "${ATLASSIAN_API_TOKEN:-}" ]]; then
  jira_payload="$(curl -fsS -u "${ATLASSIAN_API_USER}:${ATLASSIAN_API_TOKEN}" \
    "${ATLASSIAN_BASE_URL%/}/rest/api/3/issue/${jira_key}?fields=summary,description" \
    2>/dev/null || true)"
  jira_context="$(JIRA_JSON="$jira_payload" python3 - <<'PY' || true
import json, os, sys
try:
    data = json.loads(os.environ.get("JIRA_JSON") or "{}")
except Exception:
    sys.exit(0)
fields = data.get("fields") or {}
print("Summary: " + str(fields.get("summary") or ""))
print()
print("Description:")
print(json.dumps(fields.get("description"), indent=2))
PY
  )"
fi

mkdir -p "$PRE_RESOLUTION_DIR"

python3 - "$FILES_FILE" "$SNAPSHOT_FILE" "$PRE_RESOLUTION_DIR" > /dev/null <<'PY'
import json
import pathlib
import sys

files_path = pathlib.Path(sys.argv[1])
snapshot_path = pathlib.Path(sys.argv[2])
pre_resolution_root = pathlib.Path(sys.argv[3])
marker_prefixes = ("<<<<<<<", "=======", ">>>>>>>")

snapshot = {}
for name in [line.strip() for line in files_path.read_text().splitlines() if line.strip()]:
    path = pathlib.Path(name)
    pre_resolution_file = pre_resolution_root / name
    pre_resolution_file.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        pre_resolution_file.write_text(path.read_text(errors="replace"))

    lines = path.read_text(errors="replace").splitlines()
    outside = []
    in_conflict = False
    for line in lines:
        if line.startswith("<<<<<<<"):
            in_conflict = True
            continue
        if in_conflict and line.startswith(">>>>>>>"):
            in_conflict = False
            continue
        if in_conflict:
            continue
        if any(line.startswith(prefix) for prefix in marker_prefixes):
            continue
        outside.append(line)
    snapshot[name] = outside
snapshot_path.write_text(json.dumps(snapshot, indent=2) + "\n")
PY

{
  echo "# Autonomous conflict-resolution context"
  echo
  echo "Repository: \`$REPO\`"
  echo "Pull request: \`#$PR_NUMBER\`"
  echo "Base branch: \`$BASE_BRANCH\`"
  echo
  echo "## Pull request metadata"
  PR_JSON="$pr_json" python3 - <<'PY'
import json, os
try:
    data = json.loads(os.environ.get("PR_JSON") or "{}")
except Exception:
    data = {}
for key, label in (("title", "Title"), ("url", "URL"), ("headRefName", "Head"), ("baseRefName", "Base")):
    print(f"- {label}: {data.get(key) or 'Unavailable'}")
print()
print(data.get("body") or "No PR body available.")
PY
  echo
  echo "## Linked Jira context"
  if [[ -n "$jira_context" ]]; then
    echo "Jira key: \`$jira_key\`"
    echo
    printf '%s\n' "$jira_context"
  elif [[ -n "$jira_key" ]]; then
    echo "Detected Jira key \`$jira_key\`, but Atlassian credentials were not available to fetch acceptance criteria. Use the PR body as the source of intent."
  else
    echo "No Jira key detected in the PR title/body. Use the PR body as the source of intent."
  fi
  echo
  echo "## Base-branch commits being integrated"
  if git rev-parse ORIG_HEAD >/dev/null 2>&1; then
    git log --oneline --no-decorate "ORIG_HEAD..origin/${BASE_BRANCH}" 2>/dev/null || echo "Unable to list base commits from ORIG_HEAD..origin/${BASE_BRANCH}."
  else
    echo "ORIG_HEAD unavailable."
  fi
  echo
  echo "## Conflicting files"
  sed 's/^/- /' "$FILES_FILE"
  echo
  echo "## Conflict hunks (20 lines of surrounding context)"
} > "$CONTEXT_FILE"

python3 - "$FILES_FILE" >> "$CONTEXT_FILE" <<'PY'
import pathlib
import sys

files = [line.strip() for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
context = 20
for name in files:
    path = pathlib.Path(name)
    lines = path.read_text(errors="replace").splitlines()
    marker_indexes = [i for i, line in enumerate(lines) if line.startswith("<<<<<<<")]
    print(f"\n### {name}\n")
    if not marker_indexes:
        print("No conflict markers found in this file despite Git reporting it as unresolved.")
        continue
    emitted = []
    for idx in marker_indexes:
        start = max(0, idx - context)
        end = min(len(lines), idx + context + 1)
        while end < len(lines) and not lines[end - 1].startswith(">>>>>>>"):
            end += 1
        block = (start, min(len(lines), end + context))
        if emitted and block[0] <= emitted[-1][1]:
            emitted[-1] = (emitted[-1][0], max(emitted[-1][1], block[1]))
        else:
            emitted.append(block)
    for start, end in emitted:
        print(f"Lines {start + 1}-{end}:")
        print("```diff")
        for lineno in range(start, end):
            print(f"{lineno + 1:>5}: {lines[lineno]}")
        print("```")
PY

echo "context_file=$CONTEXT_FILE"
echo "files_file=$FILES_FILE"
echo "snapshot_file=$SNAPSHOT_FILE"
