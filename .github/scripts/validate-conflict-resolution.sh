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

MARKER_PREFIXES = ("<<<<<<<", "=======", ">>>>>>>")


def parse_segments(lines):
    segments = []
    segment = []
    in_conflict = False
    has_conflict = False

    for line in lines:
        if line.startswith("<<<<<<<"):
            segments.append(segment)
            segment = []
            in_conflict = True
            has_conflict = True
            continue
        if in_conflict:
            if line.startswith(">>>>>>>"):
                in_conflict = False
            continue
        if any(line.startswith(prefix) for prefix in MARKER_PREFIXES):
            continue
        segment.append(line)

    if in_conflict:
        return None, has_conflict, True

    segments.append(segment)
    return segments, has_conflict, False


def find_segment(lines, segment, start):
    if not segment:
        return start
    limit = len(lines) - len(segment) + 1
    for index in range(start, limit):
        if lines[index:index + len(segment)] == segment:
            return index
    return -1


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

    pre_resolution_lines = pre_resolution_path.read_text(errors="replace").splitlines()
    current = path.read_text(errors="replace").splitlines()
    segments, has_conflict, unterminated = parse_segments(pre_resolution_lines)
    if unterminated:
        print(f"Pre-resolution snapshot has an unterminated conflict block in {name}", file=sys.stderr)
        sys.exit(1)
    if segments is None:
        print(f"Failed to parse conflict markers in pre-resolution snapshot for {name}.", file=sys.stderr)
        sys.exit(1)

    expected_outside = [line for segment in segments for line in segment]
    if expected_outside != outside_lines:
        print(f"Outside snapshot does not match pre-resolution context for {name}", file=sys.stderr)
        sys.exit(1)

    if not has_conflict:
        if current != pre_resolution_lines:
            print(f"Non-conflict context changed in {name}: {current!r}", file=sys.stderr)
            print(f"Expected (snapshot): {pre_resolution_lines!r}", file=sys.stderr)
            sys.exit(1)
        continue

    cursor = 0
    first_non_empty = next((i for i, segment in enumerate(segments) if segment), None)
    last_non_empty = None

    for index, segment in enumerate(segments):
        if not segment:
            continue
        found = find_segment(current, segment, cursor)
        if found < 0:
            print(f"Non-conflict context changed, moved, or had lines inserted in {name}: {segment!r}", file=sys.stderr)
            sys.exit(1)
        if index == first_non_empty and index == 0 and found != 0:
            print(f"Out-of-scope changes were prepended to {name}.", file=sys.stderr)
            sys.exit(1)
        cursor = found + len(segment)
        last_non_empty = index

    if last_non_empty is not None and last_non_empty == len(segments) - 1 and segments[-1] and cursor != len(current):
        print(f"Non-conflict context changed or lines were inserted after the final conflict in {name}", file=sys.stderr)
        sys.exit(1)

print("Conflict resolution validation passed.")
PY
