#!/usr/bin/env python3
"""Validate a website preview artifact manifest before production promotion."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--artifact", required=True)
    parser.add_argument("--pr-number", required=True)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()

    manifest = json.loads(Path(args.manifest).read_text())
    artifact = Path(args.artifact)
    actual_sha = sha256(artifact)

    errors: list[str] = []
    if str(manifest.get("pr_number")) != str(args.pr_number):
        errors.append("manifest pr_number does not match")
    if manifest.get("source_sha") != args.source_sha:
        errors.append("manifest source_sha does not match")
    if manifest.get("artifact_sha256") != actual_sha:
        errors.append("manifest artifact_sha256 does not match artifact")

    if errors:
        raise SystemExit("; ".join(errors))

    print(f"Validated preview artifact for PR #{args.pr_number} at {args.source_sha}")


if __name__ == "__main__":
    main()
