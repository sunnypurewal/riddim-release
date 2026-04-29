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

Age rating env vars (all default to safe "none/false" values):
  ASC_AGE_GUNS_OR_OTHER_WEAPONS    — NONE | INFREQUENT_OR_MILD | FREQUENT_OR_INTENSE (default: NONE)
  ASC_AGE_MESSAGING_AND_CHAT       — true | false (default: false)
  ASC_AGE_USER_GENERATED_CONTENT   — true | false (default: false)
  ASC_AGE_ADVERTISING              — true | false (default: false)
  ASC_AGE_HEALTH_OR_WELLNESS       — true | false (default: false)
  ASC_AGE_PARENTAL_CONTROLS        — true | false (default: false)
  ASC_AGE_ASSURANCE                — true | false (default: false)
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


def env_bool(var, default=False):
    val = os.environ.get(var, "").lower()
    if val in ("1", "true", "yes"):
        return True
    if val in ("0", "false", "no"):
        return False
    return default


def patch_age_rating(app_id, token):
    """Ensure the pending appInfo's ageRatingDeclaration has all required fields set.

    Apple added several new required fields in 2025/2026. They are null on
    newly created versions and must be filled before review submission.
    Only patches fields that are currently null to avoid overwriting
    intentional values set in App Store Connect.
    """
    resp = api("GET", f"/apps/{app_id}/appInfos", token, params={
        "include": "ageRatingDeclaration",
    })
    all_infos = resp.get("data", [])
    # appInfos doesn't support filter[appStoreState] — filter client-side.
    app_infos = [
        i for i in all_infos
        if i["attributes"].get("appStoreState") == "PREPARE_FOR_SUBMISSION"
    ]
    if not app_infos:
        print("WARNING: No appInfo in PREPARE_FOR_SUBMISSION — skipping age rating patch.")
        return

    # The included ageRatingDeclaration shares its ID with the appInfo.
    decl_id = app_infos[0]["id"]
    included = {r["id"]: r for r in resp.get("included", [])}
    current = included.get(decl_id, {}).get("attributes", {})

    # Build the patch with only the null fields from the new required set.
    updates = {}

    gun_val = current.get("gunsOrOtherWeapons")
    if gun_val is None:
        updates["gunsOrOtherWeapons"] = os.environ.get("ASC_AGE_GUNS_OR_OTHER_WEAPONS", "NONE")

    for bool_field, env_var in [
        ("messagingAndChat",    "ASC_AGE_MESSAGING_AND_CHAT"),
        ("userGeneratedContent","ASC_AGE_USER_GENERATED_CONTENT"),
        ("advertising",         "ASC_AGE_ADVERTISING"),
        ("healthOrWellnessTopics", "ASC_AGE_HEALTH_OR_WELLNESS"),
        ("parentalControls",    "ASC_AGE_PARENTAL_CONTROLS"),
        ("ageAssurance",        "ASC_AGE_ASSURANCE"),
    ]:
        if current.get(bool_field) is None:
            updates[bool_field] = env_bool(env_var, default=False)

    if not updates:
        print("Age rating declaration: all required fields already set.")
        return

    print(f"Patching age rating declaration (null fields only): {list(updates.keys())}")
    api("PATCH", f"/ageRatingDeclarations/{decl_id}", token, json={
        "data": {
            "type": "ageRatingDeclarations",
            "id": decl_id,
            "attributes": updates,
        }
    })
    print("Age rating declaration updated.")


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

    # 4 — ensure age rating declaration has all required fields set
    patch_age_rating(app_id, token)

    # 5 — submit for review via reviewSubmissions (replaces deprecated appStoreVersionSubmissions)
    # Reuse an existing READY_FOR_REVIEW submission if one exists (avoids duplicates
    # when re-running after a partial failure).
    existing = api("GET", "/reviewSubmissions", token, params={
        "filter[app]": app_id,
        "filter[platform]": "IOS",
        "filter[state]": "READY_FOR_REVIEW",
    })
    open_subs = existing.get("data", [])
    if open_subs:
        sub_id = open_subs[0]["id"]
        print(f"Reusing existing review submission {sub_id}.")
    else:
        sub = api("POST", "/reviewSubmissions", token, json={
            "data": {
                "type": "reviewSubmissions",
                "attributes": {"platform": "IOS"},
                "relationships": {
                    "app": {"data": {"type": "apps", "id": app_id}}
                },
            }
        })
        sub_id = sub["data"]["id"]
        print(f"Created review submission {sub_id}.")

    # Check whether the version is already attached; add it if not.
    items_resp = api("GET", f"/reviewSubmissions/{sub_id}/items", token)
    attached_version_ids = {
        item["relationships"]["appStoreVersion"]["data"]["id"]
        for item in items_resp.get("data", [])
        if item.get("relationships", {}).get("appStoreVersion", {}).get("data")
    }
    if version_id not in attached_version_ids:
        api("POST", "/reviewSubmissionItems", token, json={
            "data": {
                "type": "reviewSubmissionItems",
                "relationships": {
                    "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
                    "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}},
                },
            }
        })

    api("PATCH", f"/reviewSubmissions/{sub_id}", token, json={
        "data": {
            "type": "reviewSubmissions",
            "id": sub_id,
            "attributes": {"submitted": True},
        }
    })
    print(f"Submitted version {version_str} for App Store review.")


if __name__ == "__main__":
    main()
