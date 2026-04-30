#!/usr/bin/env bash
# Validate that a conflict resolver only touched originally-conflicted files and
# preserved all non-conflict lines around the conflict regions.
#
# Usage: validate-conflict-resolution.sh <conflicted-files.txt> <outside-snapshot.json> [pre_resolution_dir]

set -euo pipefail

usage() {
  echo "Usage: $0 <conflicted-files.txt> <outside-snapshot.json> [pre_resolution_dir]" >&2
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
  usage
  exit 2
fi

FILES_FILE="$1"
SNAPSHOT_FILE="$2"
PRE_RESOLUTION_DIR="${3:-/tmp/pre_resolution}"

if [[ ! -s "$FILES_FILE" ]]; then
  echo "Error: conflicted files list is missing or empty: $FILES_FILE" >&2
  exit 2
fi
if [[ ! -s "$SNAPSHOT_FILE" ]]; then
  echo "Error: outside snapshot is missing or empty: $SNAPSHOT_FILE" >&2
  exit 2
fi
if [[ ! -d "$PRE_RESOLUTION_DIR" ]]; then
  echo "Error: pre-resolution snapshot directory missing: $PRE_RESOLUTION_DIR" >&2
  exit 2
fi

if git grep -nE '^(<<<<<<<|=======|>>>>>>>)' -- . >/tmp/conflict-markers.$$ 2>/dev/null; then
  echo "Unresolved conflict markers remain:" >&2
  cat /tmp/conflict-markers.$$ >&2
  rm -f /tmp/conflict-markers.$$
  exit 1
fi
rm -f /tmp/conflict-markers.$$

python3 - "$FILES_FILE" "$SNAPSHOT_FILE" "$PRE_RESOLUTION_DIR" <<'PY'
import json
import pathlib
import subprocess
import sys

files_path = pathlib.Path(sys.argv[1])
snapshot_path = pathlib.Path(sys.argv[2])
pre_resolution_root = pathlib.Path(sys.argv[3])
allowed = {line.strip() for line in files_path.read_text().splitlines() if line.strip()}
snapshot = json.loads(snapshot_path.read_text())

changed = subprocess.check_output(["git", "diff", "--name-only"], text=True).splitlines()
staged = subprocess.check_output(["git", "diff", "--cached", "--name-only"], text=True).splitlines()
changed_set = {line.strip() for line in changed + staged if line.strip()}
extra = sorted(changed_set - allowed)
if extra:
    print("Resolution changed files that were not originally conflicted:", file=sys.stderr)
    for name in extra:
        print(f"- {name}", file=sys.stderr)
    sys.exit(1)

for name, outside_lines in snapshot.items():
    path = pathlib.Path(name)
    pre_resolution_path = pre_resolution_root / name
    if not pre_resolution_path.exists():
        print(f"Pre-resolution snapshot missing for: {name} (expected: {pre_resolution_path})", file=sys.stderr)
        sys.exit(1)
    if not path.exists():
        print(f"Resolved file was deleted: {name}", file=sys.stderr)
        sys.exit(1)
    current = path.read_text(errors="replace").splitlines()
    pos = 0
    for expected in outside_lines:
        try:
            found = current.index(expected, pos)
        except ValueError:
            print(f"Non-conflict context line changed or removed in {name}: {expected!r}", file=sys.stderr)
            sys.exit(1)
        pos = found + 1

print("Conflict resolution validation passed.")
PY

git diff --check
