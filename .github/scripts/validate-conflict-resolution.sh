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
  segments = [[]]
  segment = []
  in_conflict = False
  has_conflict = False

  for line in lines:
    if line.startswith("<<<<<<<"):
      segments.append(segment)
      segment = []
      has_conflict = True
      in_conflict = True
      continue
    if in_conflict:
      if line.startswith(">>>>>>>"):
        in_conflict = False
      continue
    if any(line.startswith(prefix) for prefix in MARKER_PREFIXES):
      continue
    segment.append(line)

  if in_conflict:
    print("Pre-resolution snapshot has an unterminated conflict block.", file=sys.stderr)
    return None, False, True

  segments.append(segment)
  return segments, has_conflict, False


def find_subsequence(haystack, needle, start):
  if not needle:
    return start
  limit = len(haystack) - len(needle) + 1
  for index in range(start, limit):
    if haystack[index : index + len(needle)] == needle:
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
  if segments is None:
    print(f"Failed to parse conflict markers in pre-resolution snapshot for {name}.", file=sys.stderr)
    sys.exit(1)

  expected_lines = [line for segment in segments for line in segment]
  if expected_lines != outside_lines:
    print(
      f"Outside snapshot does not match pre-resolution context for {name}.\n"
      f"  expected: {outside_lines!r}\n"
      f"  observed: {expected_lines!r}",
      file=sys.stderr,
    )
    sys.exit(1)

  if not has_conflict:
    if current != pre_resolution_lines:
      print(f"Non-conflict context changed in {name}: {current!r}", file=sys.stderr)
      print(f"Expected (snapshot): {pre_resolution_lines!r}", file=sys.stderr)
      sys.exit(1)
    continue

  cursor = 0
  first_non_empty_index = None
  last_non_empty_index = None

  for i, segment in enumerate(segments):
    if not segment:
      continue
    if first_non_empty_index is None:
      first_non_empty_index = i
    found = find_subsequence(current, segment, cursor)
    if found == -1:
      print(
        f"Non-conflict context line changed or removed in {name}: {segment!r}",
        file=sys.stderr,
      )
      sys.exit(1)
    if i == 0 and found > 0:
      print(f"Out-of-scope changes were prepended to {name}.", file=sys.stderr)
      sys.exit(1)
    if found < cursor:
      print(f"Non-conflict lines are out of order in {name}: {segment!r}", file=sys.stderr)
      sys.exit(1)
    cursor = found + len(segment)
    last_non_empty_index = i

  if last_non_empty_index is None:
    continue

  if first_non_empty_index is None:
    # Entire file was conflicted and now contains only resolver output.
    continue

  if last_non_empty_index == len(segments) - 1 and segments[-1]:
    if cursor != len(current):
      print(f"Non-conflict context changed or appended in {name}.", file=sys.stderr)
      sys.exit(1)

print("Conflict resolution validation passed.")
PY

git diff --check
