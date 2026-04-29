#!/usr/bin/env python3
"""Package a static website into an Amplify manual-deploy zip artifact."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_EXCLUDES = (
    ".git",
    ".git/*",
    ".github",
    ".github/*",
    ".DS_Store",
    "docs",
    "docs/*",
    "node_modules",
    "node_modules/*",
    "dist",
    "dist/*",
    "site.zip",
    "*.zip",
    "amplify.yml",
    "customHttp.yml",
)


def run(command: str, cwd: Path) -> None:
    subprocess.run(command, cwd=cwd, shell=True, check=True)


def git_files(root: Path) -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=root,
        capture_output=True,
        check=True,
    )
    return [root / item.decode() for item in result.stdout.split(b"\0") if item]


def walked_files(root: Path) -> list[Path]:
    return [path for path in root.rglob("*") if path.is_file()]


def is_excluded(relative: str, patterns: tuple[str, ...]) -> bool:
    normalized = relative.replace(os.sep, "/")
    return any(fnmatch.fnmatch(normalized, pattern) for pattern in patterns)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def package_files(source: Path, publish_dir: Path, output: Path, excludes: tuple[str, ...]) -> list[str]:
    output.parent.mkdir(parents=True, exist_ok=True)
    files = git_files(publish_dir) if (publish_dir / ".git").exists() else walked_files(publish_dir)

    added: list[str] = []
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for file_path in sorted(files):
            relative = file_path.relative_to(publish_dir).as_posix()
            if is_excluded(relative, excludes):
                continue
            archive.write(file_path, relative)
            added.append(relative)

    if not added:
        raise RuntimeError(f"No files were packaged from {publish_dir}")

    return added


def write_manifest(args: argparse.Namespace, packaged_files: list[str], artifact_sha: str) -> None:
    manifest = {
        "artifact": str(args.output),
        "artifact_sha256": artifact_sha,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "file_count": len(packaged_files),
        "preview_branch": args.preview_branch,
        "preview_url": args.preview_url,
        "production_branch": args.production_branch,
        "pr_number": args.pr_number,
        "source_ref": args.source_ref,
        "source_sha": args.source_sha,
    }
    manifest_path = Path(args.manifest)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", default=".")
    parser.add_argument("--publish-dir", default="")
    parser.add_argument("--build-command", default="")
    parser.add_argument("--output", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--preview-branch", required=True)
    parser.add_argument("--preview-url", required=True)
    parser.add_argument("--production-branch", default="main")
    parser.add_argument("--pr-number", required=True)
    parser.add_argument("--source-ref", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--exclude", action="append", default=[])
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    source = Path(args.source_dir).resolve()
    if not source.is_dir():
        raise SystemExit(f"source directory does not exist: {source}")

    if args.build_command:
        run(args.build_command, source)

    publish_dir = (source / args.publish_dir).resolve() if args.publish_dir else source
    if not publish_dir.is_dir():
        raise SystemExit(f"publish directory does not exist: {publish_dir}")

    output = Path(args.output).resolve()
    excludes = tuple(DEFAULT_EXCLUDES + tuple(args.exclude))
    packaged_files = package_files(source, publish_dir, output, excludes)
    artifact_sha = sha256(output)
    write_manifest(args, packaged_files, artifact_sha)

    print(f"Packaged {len(packaged_files)} file(s) into {output}")
    print(f"artifact_sha256={artifact_sha}")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        sys.exit(exc.returncode)
