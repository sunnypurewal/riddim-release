#!/usr/bin/env python3
"""
Verify that every PR merged to main since the last release tag has a
screenshot in docs/build-evidence/.

Exits 0 if all evidence is present. Writes missing_count and details to
GITHUB_OUTPUT (or stdout if not in Actions).

Usage:
  python3 verify_evidence.py --ticket-prefix RIDDIM --evidence-dir docs/build-evidence
"""
import argparse
import os
import re
import subprocess
import sys


def git(*args: str) -> str:
    result = subprocess.run(["git"] + list(args), capture_output=True, text=True, check=True)
    return result.stdout.strip()


def get_last_release_tag() -> str | None:
    try:
        return git("describe", "--tags", "--abbrev=0", "--match", "v*")
    except subprocess.CalledProcessError:
        return None


def get_prs_since_tag(tag: str | None) -> list[str]:
    """Return merge commit messages (PR titles) since the last release tag."""
    if tag:
        log = git("log", f"{tag}..HEAD", "--oneline", "--merges")
    else:
        log = git("log", "--oneline", "--merges", "-50")
    return [line for line in log.splitlines() if line]


def ticket_pattern(ticket_prefix: str) -> str:
    return rf"{re.escape(ticket_prefix)}-\d+"


def extract_ticket_ids(pr_lines: list[str], ticket_prefix: str) -> set[str]:
    """Extract PREFIX-NNN ticket IDs from merge commit messages."""
    ids: set[str] = set()
    for line in pr_lines:
        ids.update(re.findall(ticket_pattern(ticket_prefix), line, re.IGNORECASE))
    return {t.upper() for t in ids}


def get_evidenced_tickets(evidence_dir: str, ticket_prefix: str) -> set[str]:
    """Return ticket IDs that have at least one screenshot in docs/build-evidence/."""
    if not os.path.isdir(evidence_dir):
        return set()
    ids: set[str] = set()
    for fname in os.listdir(evidence_dir):
        ids.update(re.findall(ticket_pattern(ticket_prefix), fname, re.IGNORECASE))
    return {t.upper() for t in ids}


def write_output(key: str, value: str) -> None:
    output_file = os.environ.get("GITHUB_OUTPUT", "")
    if output_file:
        with open(output_file, "a") as f:
            f.write(f"{key}={value}\n")
    else:
        print(f"{key}={value}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--ticket-prefix",
        required=True,
        help="Ticket key prefix to require in merge commits and evidence filenames, e.g. EPAC",
    )
    parser.add_argument("--evidence-dir", default="docs/build-evidence")
    parser.add_argument(
        "--fail-on-missing",
        action="store_true",
        help="Exit non-zero if any evidence is missing",
    )
    args = parser.parse_args()

    last_tag = get_last_release_tag()
    pr_lines = get_prs_since_tag(last_tag)
    merged_tickets = extract_ticket_ids(pr_lines, args.ticket_prefix)
    evidenced_tickets = get_evidenced_tickets(args.evidence_dir, args.ticket_prefix)

    missing = merged_tickets - evidenced_tickets
    missing_count = len(missing)

    write_output("missing_count", str(missing_count))
    write_output("missing_tickets", ",".join(sorted(missing)))

    if missing_count > 0:
        print(f"WARNING: {missing_count} ticket(s) missing build evidence: {', '.join(sorted(missing))}")
        print(f"(Checked {args.evidence_dir} for files containing ticket IDs)")
        if args.fail_on_missing:
            sys.exit(1)
    else:
        print(f"All {len(merged_tickets)} merged tickets have evidence screenshots.")


if __name__ == "__main__":
    main()
