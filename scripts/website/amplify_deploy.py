#!/usr/bin/env python3
"""Deploy a zip artifact to an AWS Amplify Hosting branch."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path


def aws(*args: str) -> dict:
    result = subprocess.run(
        ["aws", *args, "--output", "json"],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(result.stdout or "{}")


def branch_exists(app_id: str, branch: str) -> bool:
    try:
        aws("amplify", "get-branch", "--app-id", app_id, "--branch-name", branch)
        return True
    except subprocess.CalledProcessError as exc:
        if "NotFoundException" in exc.stderr:
            return False
        raise


def ensure_branch(app_id: str, branch: str, stage: str) -> None:
    if branch_exists(app_id, branch):
        return
    aws(
        "amplify",
        "create-branch",
        "--app-id",
        app_id,
        "--branch-name",
        branch,
        "--stage",
        stage,
        "--no-enable-auto-build",
    )


def deploy(app_id: str, branch: str, artifact: Path, timeout_seconds: int) -> str:
    deployment = aws("amplify", "create-deployment", "--app-id", app_id, "--branch-name", branch)
    upload_url = deployment["zipUploadUrl"]
    job_id = deployment["jobId"]

    subprocess.run(
        ["curl", "--fail", "--silent", "--show-error", "-X", "PUT", "-T", str(artifact), upload_url],
        check=True,
    )

    aws("amplify", "start-deployment", "--app-id", app_id, "--branch-name", branch, "--job-id", job_id)

    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        job = aws("amplify", "get-job", "--app-id", app_id, "--branch-name", branch, "--job-id", job_id)
        status = job["job"]["summary"]["status"]
        print(f"Amplify deployment status: {status}")
        if status == "SUCCEED":
            return job_id
        if status in {"FAILED", "CANCELLED"}:
            raise RuntimeError(f"Amplify deployment {job_id} ended with {status}")
        time.sleep(5)

    raise TimeoutError(f"Timed out waiting for Amplify deployment {job_id}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-id", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--artifact", required=True)
    parser.add_argument("--stage", choices=["DEVELOPMENT", "PRODUCTION"], default="DEVELOPMENT")
    parser.add_argument("--create-branch", action="store_true")
    parser.add_argument("--timeout-seconds", type=int, default=300)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    artifact = Path(args.artifact).resolve()
    if not artifact.is_file():
        raise SystemExit(f"artifact does not exist: {artifact}")

    if args.create_branch:
        ensure_branch(args.app_id, args.branch, args.stage)

    job_id = deploy(args.app_id, args.branch, artifact, args.timeout_seconds)
    print(f"job_id={job_id}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, TimeoutError, subprocess.CalledProcessError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
