#!/usr/bin/env python3
"""
Find a TestFlight build to submit to the App Store.

Two modes:
  --latest         Return the most recent valid build (no cutoff). Used when a
                   git tag is the release signal and the developer controls timing.
  --cutoff-hour N  Return the most recent valid build uploaded before N:00 ET
                   (legacy daily-release mode).

Usage:
  python3 find_qualifying_build.py \
    --key-id S6U297PQHR \
    --issuer-id 69a6de88-... \
    --private-key-path ~/.appstoreconnect/private_keys/AuthKey_S6U297PQHR.p8 \
    --app-id 1224459142 \
    --latest \
    [--override 1234] \
    [--output-format github-output]
"""
import argparse
import os
import time
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

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


def find_qualifying_build(app_id: str, cutoff_dt: datetime | None, token: str, override: str | None, version: str | None = None) -> dict:
    headers = {"Authorization": f"Bearer {token}"}
    url = "https://api.appstoreconnect.apple.com/v1/builds"
    params = {
        "filter[app]": app_id,
        "filter[processingState]": "VALID",
        "sort": "-uploadedDate",
        "limit": 50,
        "fields[builds]": "version,uploadedDate,processingState,preReleaseVersion",
        "include": "preReleaseVersion",
    }

    resp = requests.get(url, headers=headers, params=params, timeout=30)
    resp.raise_for_status()
    data = resp.json()

    # Build a version map from included preReleaseVersion resources
    version_map: dict[str, str] = {}
    for inc in data.get("included", []):
        if inc.get("type") == "preReleaseVersions":
            version_map[inc["id"]] = inc["attributes"]["version"]

    for build in data["data"]:
        attrs = build["attributes"]
        build_number = attrs["version"]

        if override and build_number != str(override):
            continue

        uploaded_raw = attrs["uploadedDate"]
        uploaded = datetime.fromisoformat(uploaded_raw.replace("Z", "+00:00"))

        if cutoff_dt is not None and uploaded > cutoff_dt:
            continue

        # Resolve app version string from the preReleaseVersion relationship
        prv_rel = build.get("relationships", {}).get("preReleaseVersion", {})
        prv_id = (prv_rel.get("data") or {}).get("id", "")
        build_version = version_map.get(prv_id, "unknown")

        if version and build_version != version:
            continue

        return {
            "build_number": build_number,
            "build_version": build_version,
            "upload_time": uploaded_raw,
        }

    cutoff_msg = f" before cutoff {cutoff_dt.isoformat()}" if cutoff_dt else ""
    raise SystemExit(
        f"No qualifying build found{cutoff_msg}"
        + (f" (override={override})" if override else "")
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer-id", required=True)
    parser.add_argument("--private-key-path", required=True)
    parser.add_argument("--app-id", required=True)
    parser.add_argument("--latest", action="store_true", help="Return the most recent valid build (no cutoff)")
    parser.add_argument("--cutoff-hour", type=int, default=14, help="Hour (24h) in Eastern Time; ignored when --latest is set")
    parser.add_argument("--override", default="", help="Force a specific build number")
    parser.add_argument("--version", default="", help="Filter by marketing version string (CFBundleShortVersionString)")
    parser.add_argument(
        "--output-format",
        choices=["github-output", "text"],
        default="text",
    )
    args = parser.parse_args()

    if args.latest:
        cutoff_dt = None
    else:
        et = ZoneInfo("America/New_York")
        today = datetime.now(et).date()
        cutoff_dt = datetime(today.year, today.month, today.day, args.cutoff_hour, 0, 0, tzinfo=et).astimezone(timezone.utc)

    token = get_asc_token(args.key_id, args.issuer_id, args.private_key_path)
    result = find_qualifying_build(args.app_id, cutoff_dt, token, args.override or None, args.version or None)

    if args.output_format == "github-output":
        output_file = os.environ.get("GITHUB_OUTPUT", "/dev/stdout")
        with open(output_file, "a") as f:
            f.write(f"build_number={result['build_number']}\n")
            f.write(f"build_version={result['build_version']}\n")
            f.write(f"upload_time={result['upload_time']}\n")
        print(
            f"Qualifying build: {result['build_version']} "
            f"(#{result['build_number']}) uploaded {result['upload_time']}"
        )
    else:
        for k, v in result.items():
            print(f"{k}={v}")


if __name__ == "__main__":
    main()
