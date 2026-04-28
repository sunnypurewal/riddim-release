#!/usr/bin/env python3
"""
Generate App Store release notes from `Release-Note:` lines in PR descriptions
merged since the last release tag.

Writes the result to the required output path (or stdout with --dry-run).

Usage:
  python3 generate_release_notes.py --output ios/fastlane/metadata/en-US/release_notes.txt
"""
import argparse
import os
import re
import subprocess
import sys


def gh(*args: str) -> str:
    result = subprocess.run(["gh"] + list(args), capture_output=True, text=True)
    if result.returncode != 0:
        print(f"gh error: {result.stderr}", file=sys.stderr)
        return ""
    return result.stdout.strip()


def git(*args: str) -> str:
    result = subprocess.run(["git"] + list(args), capture_output=True, text=True, check=True)
    return result.stdout.strip()


def get_last_release_tag() -> str | None:
    try:
        return git("describe", "--tags", "--abbrev=0", "--match", "v*")
    except subprocess.CalledProcessError:
        return None


def get_merged_pr_numbers(last_tag: str | None) -> list[str]:
    """Return PR numbers from merge commits since the last release tag."""
    if last_tag:
        log = git("log", f"{last_tag}..HEAD", "--oneline", "--merges")
    else:
        log = git("log", "--oneline", "--merges", "-30")

    pr_numbers: list[str] = []
    for line in log.splitlines():
        match = re.search(r"\(#(\d+)\)", line)
        if match:
            pr_numbers.append(match.group(1))
    return pr_numbers


def extract_release_notes_from_pr(pr_number: str) -> list[str]:
    """Fetch PR body and extract Release-Note: lines."""
    body = gh("pr", "view", pr_number, "--json", "body", "--jq", ".body")
    notes: list[str] = []
    for line in body.splitlines():
        match = re.match(r"^Release-Note:\s*(.+)", line.strip(), re.IGNORECASE)
        if match:
            notes.append(match.group(1).strip())
    return notes


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        required=True,
        help="Path to write the generated release notes",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print to stdout only, don't write to file",
    )
    args = parser.parse_args()

    last_tag = get_last_release_tag()
    pr_numbers = get_merged_pr_numbers(last_tag)

    notes: list[str] = []
    for pr_num in pr_numbers:
        notes.extend(extract_release_notes_from_pr(pr_num))

    if not notes:
        print("No Release-Note: lines found in merged PRs — using existing release_notes.txt unchanged.")
        return

    bullets = "\n".join(f"• {n}" for n in notes)
    content = f"What's new in this release:\n\n{bullets}\n"

    if args.dry_run:
        print(content)
        return

    parent = os.path.dirname(args.output)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(args.output, "w") as f:
        f.write(content)

    print(f"Wrote {len(notes)} release note(s) to {args.output}")
    print(content)


if __name__ == "__main__":
    main()
