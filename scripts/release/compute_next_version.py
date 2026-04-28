#!/usr/bin/env python3
"""
Compute the next marketing version for an App Store submission.

Queries the current live App Store version via the App Store Connect API and
applies a semver bump. Falls back to the latest git tag if no live version
exists (first release), and to 0.0.0 if there are no tags.

Usage:
  python3 compute_next_version.py \
    --key-id S6U297PQHR \
    --issuer-id 69a6de88-... \
    --private-key-path ~/.appstoreconnect/private_keys/AuthKey_S6U297PQHR.p8 \
    --app-id 1224459142 \
    --bump patch|minor|major \
    [--output-format github-output]
"""
import argparse
import os
import subprocess
import time

import jwt
import requests


def get_asc_token(key_id: str, issuer_id: str, private_key_path: str) -> str:
    with open(os.path.expanduser(private_key_path)) as f:
        private_key = f.read()
    now = int(time.time())
    payload = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + 1200,
        "aud": "appstoreconnect-v1",
    }
    return jwt.encode(payload, private_key, algorithm="ES256", headers={"kid": key_id})


def get_live_version(app_id: str, token: str) -> str | None:
    """Return the current READY_FOR_SALE marketing version, or None if no live version."""
    headers = {"Authorization": f"Bearer {token}"}
    url = f"https://api.appstoreconnect.apple.com/v1/apps/{app_id}/appStoreVersions"
    params = {
        "filter[platform]": "IOS",
        "filter[appStoreState]": "READY_FOR_SALE",
        "fields[appStoreVersions]": "versionString",
        "limit": 1,
    }
    resp = requests.get(url, headers=headers, params=params, timeout=30)
    resp.raise_for_status()
    data = resp.json().get("data", [])
    return data[0]["attributes"]["versionString"] if data else None


def get_latest_git_tag() -> str | None:
    try:
        result = subprocess.run(
            ["git", "describe", "--tags", "--abbrev=0", "--match", "v*"],
            capture_output=True, text=True, check=True,
        )
        return result.stdout.strip().lstrip("v")
    except subprocess.CalledProcessError:
        return None


def bump_version(version: str, bump: str) -> str:
    parts = (version.split(".") + ["0", "0"])[:3]
    major, minor, patch = int(parts[0]), int(parts[1]), int(parts[2])
    if bump == "major":
        return f"{major + 1}.0.0"
    if bump == "minor":
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("--private-key-path", required=True)
    parser.add_argument("--app-id", required=True)
    parser.add_argument("--bump", choices=["patch", "minor", "major"], default="patch")
    parser.add_argument("--output-format", choices=["github-output", "text"], default="text")
    args = parser.parse_args()

    token = get_asc_token(args.key_id, args.issuer_id, args.private_key_path)

    current = get_live_version(args.app_id, token)
    source = "App Store Connect (live)"
    if current is None:
        current = get_latest_git_tag()
        source = "latest git tag"
    if current is None:
        current = "0.0.0"
        source = "default (no live version or git tags)"

    next_version = bump_version(current, args.bump)
    print(f"Current version ({source}): {current}")
    print(f"Next version ({args.bump} bump): {next_version}")

    if args.output_format == "github-output":
        output_file = os.environ.get("GITHUB_OUTPUT", "/dev/stdout")
        with open(output_file, "a") as f:
            f.write(f"next_version={next_version}\n")
            f.write(f"current_version={current}\n")
    else:
        print(f"next_version={next_version}")
        print(f"current_version={current}")


if __name__ == "__main__":
    main()
