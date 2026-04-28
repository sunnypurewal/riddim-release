#!/usr/bin/env python3
from __future__ import annotations

import csv
import gzip
import hashlib
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from scripts.analytics import TOOL_VERSION

INCOMPLETE_STATUSES = {
    "delayed",
    "thresholded",
    "permission_blocked",
    "unavailable",
    "missing_segment",
    "error",
}


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def slugify(value: Any) -> str:
    slug = re.sub(r"[^a-zA-Z0-9._-]+", "-", str(value or "").strip()).strip("-").lower()
    return slug or "unknown"


def load_json(path: str | Path) -> dict[str, Any]:
    return json.loads(Path(path).read_text())


def write_json(path: str | Path, data: Any) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(target.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, target)


def app_slug(config: dict[str, Any]) -> str:
    app = config.get("app", {})
    return slugify(app.get("app_slug") or app.get("slug") or app.get("bundle_id") or app.get("app_id") or "app")


def output_root(config: dict[str, Any]) -> Path:
    output = config.get("output", {})
    root = Path(output.get("root") or config.get("output_dir") or "docs/analytics/app-store-connect")
    slug = app_slug(config)
    return root if root.name == slug else root / slug


def artifact_root(config: dict[str, Any], start_date: str, end_date: str | None = None) -> Path:
    end = end_date or start_date
    return output_root(config) / f"{start_date}_{end}"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: str | Path) -> str:
    h = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def count_gzip_tsv_rows(path: str | Path) -> int:
    try:
        with gzip.open(path, "rt", newline="") as handle:
            rows = list(csv.reader(handle, delimiter="\t"))
    except OSError:
        return 0
    return max(len(rows) - 1, 0)


def base_manifest(config: dict[str, Any], start_date: str, end_date: str | None = None) -> dict[str, Any]:
    app = config.get("app", {})
    return {
        "artifact_version": config.get("output", {}).get("artifact_version", 1),
        "tool_version": TOOL_VERSION,
        "generated_at": utc_now(),
        "app": {
            "app_id": app.get("app_id") or app.get("apple_app_id"),
            "bundle_id": app.get("bundle_id"),
            "app_slug": app_slug(config),
            "provider_id": app.get("provider_id"),
            "team_id": app.get("team_id"),
        },
        "window": {
            "start_date": start_date,
            "end_date": end_date or start_date,
            "timezone": config.get("collection", {}).get("window", {}).get("timezone", "UTC"),
        },
        "business_context": config.get("business_context_mappings") or config.get("business_context") or {},
        "reports": [],
        "completeness": {
            "status": "complete",
            "raw_file_count": 0,
            "normalized_file_count": 0,
            "schema_file_count": 0,
            "row_count": 0,
            "caveats": [],
        },
    }


def load_manifest(root: Path, config: dict[str, Any], start_date: str, end_date: str | None = None) -> dict[str, Any]:
    manifest_path = root / "manifest.json"
    if not manifest_path.exists():
        return base_manifest(config, start_date, end_date)

    manifest = load_json(manifest_path)
    manifest["generated_at"] = utc_now()
    manifest.setdefault("reports", [])
    manifest.setdefault("completeness", {})
    manifest["completeness"].setdefault("caveats", [])
    return manifest


def upsert_report(manifest: dict[str, Any], entry: dict[str, Any]) -> None:
    reports = manifest.setdefault("reports", [])
    artifact_id = entry["artifact_id"]
    for index, existing in enumerate(reports):
        if existing.get("artifact_id") == artifact_id:
            reports[index] = {**existing, **entry}
            refresh_completeness(manifest)
            return
    reports.append(entry)
    refresh_completeness(manifest)


def refresh_completeness(manifest: dict[str, Any]) -> None:
    reports = manifest.get("reports", [])
    raw_count = len([item for item in reports if item.get("raw_path")])
    row_count = sum(int(item.get("row_count") or 0) for item in reports)
    caveats = [
        item["status_reason"]
        for item in reports
        if item.get("status") in INCOMPLETE_STATUSES and item.get("status_reason")
    ]
    manifest["completeness"] = {
        "status": "incomplete" if any(item.get("status") in INCOMPLETE_STATUSES for item in reports) else "complete",
        "raw_file_count": raw_count,
        "normalized_file_count": len([item for item in reports if item.get("normalized_path")]),
        "schema_file_count": len([item for item in reports if item.get("schema_path")]),
        "row_count": row_count,
        "caveats": caveats,
    }


def existing_report(manifest: dict[str, Any], artifact_id: str) -> dict[str, Any] | None:
    for report in manifest.get("reports", []):
        if report.get("artifact_id") == artifact_id:
            return report
    return None


def manifest_entry(
    config: dict[str, Any],
    *,
    artifact_id: str,
    family: str = "analytics",
    category: str | None,
    report_type: str | None,
    subtype: str | None,
    granularity: str | None,
    requested_date: str | None,
    requested_window: dict[str, Any] | None,
    request_id: str | None,
    report_id: str | None,
    instance_id: str | None,
    segment_id: str | None,
    download_url_source: str | None,
    raw_path: Path | None,
    status: str,
    status_reason: str | None = None,
) -> dict[str, Any]:
    checksum = sha256_file(raw_path) if raw_path else None
    row_count = count_gzip_tsv_rows(raw_path) if raw_path else None
    return {
        "artifact_id": artifact_id,
        "family": family,
        "category": category,
        "type": report_type,
        "subtype": subtype,
        "granularity": granularity,
        "requested_date": requested_date,
        "requested_window": requested_window,
        "request_id": request_id,
        "report_id": report_id,
        "instance_id": instance_id,
        "segment_id": segment_id,
        "download_url_source": download_url_source,
        "raw_path": str(raw_path) if raw_path else None,
        "downloaded_at": utc_now() if raw_path else None,
        "checksum_sha256": checksum,
        "byte_count": raw_path.stat().st_size if raw_path else None,
        "row_count": row_count,
        "status": status,
        "status_reason": status_reason,
        "normalized_path": None,
        "schema_path": None,
    }


def atomic_write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)
