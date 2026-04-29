#!/usr/bin/env python3
"""Delete an AWS Amplify Hosting branch if it exists."""

from __future__ import annotations

import argparse
import subprocess
import sys


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["aws", *args], capture_output=True, text=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-id", required=True)
    parser.add_argument("--branch", required=True)
    args = parser.parse_args()

    get_result = run("amplify", "get-branch", "--app-id", args.app_id, "--branch-name", args.branch)
    if get_result.returncode != 0 and "NotFoundException" in get_result.stderr:
        print(f"Amplify branch already absent: {args.branch}")
        return
    if get_result.returncode != 0:
        print(get_result.stderr, file=sys.stderr)
        sys.exit(get_result.returncode)

    delete_result = run("amplify", "delete-branch", "--app-id", args.app_id, "--branch-name", args.branch)
    if delete_result.returncode != 0:
        print(delete_result.stderr, file=sys.stderr)
        sys.exit(delete_result.returncode)
    print(f"Deleted Amplify branch: {args.branch}")


if __name__ == "__main__":
    main()
