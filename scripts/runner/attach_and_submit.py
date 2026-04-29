#!/usr/bin/env python3
"""
attach_and_submit.py — Attach a build to the pending App Store version and
optionally submit it for App Store review.

Usage:
  python3 attach_and_submit.py <apple_app_id> <build_number> [submit=true|false]

Env (set by fetch_asc_secret.sh):
  ASC_KEY_ID     — the API key ID
  ASC_ISSUER_ID  — the issuer ID

Key file written by fetch_asc_secret.sh:
  ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
"""
import os
import sys
import time

import jwt
import requests

BASE = "https://api.appstoreconnect.apple.com/v1"


def make_token():
    key_id = os.environ["ASC_KEY_ID"]
    issuer_id = os.environ["ASC_ISSUER_ID"]
    p8 = os.path.expanduser(
        f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8"
    )
    with open(p8) as f:
        private_key = f.read()
    return jwt.encode(
        {
            "iss": issuer_id,
            "iat": int(time.time()),
            "exp": int(time.time()) + 1200,
            "aud": "appstoreconnect-v1",
        },
        private_key,
        algorithm="ES256",
        headers={"kid": key_id},
    )


def api(method, path, token, **kwargs):
    r = requests.request(
        method,
        f"{BASE}{path}",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        **kwargs,
    )
    if not r.ok:
        print(f"ASC API error {r.status_code}: {r.text}", file=sys.stderr)
        r.raise_for_status()
    return r.json() if r.content else {}


def main():
    if len(sys.argv) < 3:
        print(
            f"Usage: {sys.argv[0]} <apple_app_id> <build_number> [submit=true]",
            file=sys.stderr,
        )
        sys.exit(1)

    app_id = sys.argv[1]
    build_number = sys.argv[2]
    submit = (sys.argv[3].lower() == "true") if len(sys.argv) > 3 else True

    token = make_token()

    # 1 — find the App Store version in PREPARE_FOR_SUBMISSION
    resp = api("GET", f"/apps/{app_id}/appStoreVersions", token, params={
        "filter[appStoreState]": "PREPARE_FOR_SUBMISSION",
        "fields[appStoreVersions]": "versionString,appStoreState",
    })
    versions = resp.get("data", [])
    if not versions:
        print(
            "ERROR: No App Store version found in PREPARE_FOR_SUBMISSION state. "
            "Create one in App Store Connect before running this workflow.",
            file=sys.stderr,
        )
        sys.exit(1)
    version = versions[0]
    version_id = version["id"]
    version_str = version["attributes"]["versionString"]
    print(f"Pending version: {version_str} (id={version_id})")

    # 2 — find the build by number
    resp = api("GET", "/builds", token, params={
        "filter[app]": app_id,
        "filter[version]": build_number,
        "filter[processingState]": "VALID",
        "fields[builds]": "version,processingState,uploadedDate",
    })
    builds = resp.get("data", [])
    if not builds:
        print(
            f"ERROR: No VALID build found with number {build_number}. "
            "The build may still be processing in TestFlight — wait a few minutes and retry.",
            file=sys.stderr,
        )
        sys.exit(1)
    build = builds[0]
    build_id = build["id"]
    uploaded = build["attributes"]["uploadedDate"]
    print(f"Build {build_number}: id={build_id}, uploaded={uploaded}")

    # 3 — attach build to the version
    api("PATCH", f"/appStoreVersions/{version_id}", token, json={
        "data": {
            "type": "appStoreVersions",
            "id": version_id,
            "relationships": {
                "build": {"data": {"type": "builds", "id": build_id}}
            },
        }
    })
    print(f"Attached build {build_number} to version {version_str}.")

    if not submit:
        print("submit_for_review=false — done. Submit manually in App Store Connect.")
        return

    # 4 — submit for review
    api("POST", "/appStoreVersionSubmissions", token, json={
        "data": {
            "type": "appStoreVersionSubmissions",
            "relationships": {
                "appStoreVersion": {
                    "data": {"type": "appStoreVersions", "id": version_id}
                }
            },
        }
    })
    print(f"Submitted version {version_str} for App Store review.")


if __name__ == "__main__":
    main()
