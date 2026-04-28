#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import gzip
import json
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.analytics import TOOL_VERSION
from scripts.analytics.artifact import load_json, refresh_completeness, utc_now, write_json


def normalize_artifact(root: Path) -> dict[str, Any]:
    manifest_path = root / "manifest.json"
    manifest = load_json(manifest_path)
    summary_rows: list[dict[str, Any]] = []

    for report in manifest.get("reports", []):
        raw_path_value = report.get("raw_path")
        if not raw_path_value:
            continue
        raw_path = Path(raw_path_value)
        if not raw_path.exists():
            continue
        normalized_path = root / "normalized" / report.get("family", "unknown") / f"{report['artifact_id']}.jsonl"
        schema_path = root / "schema" / report.get("family", "unknown") / f"{report['artifact_id']}.schema.json"
        result = normalize_file(raw_path, normalized_path, report)
        report["normalized_path"] = str(normalized_path)
        report["schema_path"] = str(schema_path)
        report["row_count"] = result["row_count"]
        if result["row_count"] == 0 and report.get("status") in {"downloaded", "unchanged"}:
            report["status"] = "empty"
            report["status_reason"] = "Raw report parsed successfully but contained no data rows; this may be privacy thresholding or no available activity."
        schema_path.parent.mkdir(parents=True, exist_ok=True)
        write_json(schema_path, result["schema"])
        summary_rows.append({**report, **result})

    refresh_completeness(manifest)
    write_summary(root / "summary.md", manifest, summary_rows)
    write_json(manifest_path, manifest)
    return manifest


def normalize_file(raw_path: Path, normalized_path: Path, report: dict[str, Any]) -> dict[str, Any]:
    normalized_path.parent.mkdir(parents=True, exist_ok=True)
    columns: dict[str, dict[str, Any]] = {}
    row_count = 0
    malformed_rows = 0
    with gzip.open(raw_path, "rt", newline="") as handle, normalized_path.open("w") as out:
        reader = csv.DictReader(handle, delimiter="\t")
        source_fields = list(reader.fieldnames or [])
        for field in source_fields:
            columns[field] = {"source": True, "types": []}
        enrichment_fields = enrichment(report)
        for field in enrichment_fields:
            columns[field] = {"source": False, "types": ["string"]}
        for row in reader:
            if None in row:
                malformed_rows += 1
                row["_malformed_extra_columns"] = row.pop(None)
            enriched = {**row, **enrichment_fields}
            for key, value in row.items():
                observed = infer_type(value)
                types = columns.setdefault(key, {"source": True, "types": []})["types"]
                if observed not in types:
                    types.append(observed)
            out.write(json.dumps(enriched, sort_keys=True) + "\n")
            row_count += 1
    return {
        "row_count": row_count,
        "malformed_rows": malformed_rows,
        "schema": {
            "tool_version": TOOL_VERSION,
            "generated_at": utc_now(),
            "raw_path": str(raw_path),
            "normalized_path": str(normalized_path),
            "source_columns": source_fields,
            "columns": columns,
        },
    }


def infer_type(value: Any) -> str:
    if value in (None, ""):
        return "empty"
    text = str(value)
    try:
        int(text)
        return "integer"
    except ValueError:
        pass
    try:
        float(text)
        return "number"
    except ValueError:
        return "string"


def enrichment(report: dict[str, Any]) -> dict[str, str]:
    return {
        "_artifact_id": str(report.get("artifact_id") or ""),
        "_source_file": str(report.get("raw_path") or ""),
        "_checksum": str(report.get("checksum_sha256") or ""),
        "_report_family": str(report.get("family") or ""),
        "_report_type": str(report.get("type") or ""),
        "_granularity": str(report.get("granularity") or ""),
        "_downloaded_at": str(report.get("downloaded_at") or ""),
        "_app_id": str(report.get("app_id") or ""),
        "_bundle_id": str(report.get("bundle_id") or ""),
        "_release_tag": str(report.get("release_tag") or ""),
        "_jira_keys": ",".join(str(key) for key in report.get("jira_keys", [])),
        "_tool_version": TOOL_VERSION,
    }


def write_summary(path: Path, manifest: dict[str, Any], rows: list[dict[str, Any]]) -> None:
    app = manifest.get("app", {})
    families = sorted({row.get("family", "unknown") for row in rows})
    total_rows = sum(row.get("row_count", 0) for row in rows)
    caveats = manifest.get("completeness", {}).get("caveats", [])
    lines = [
        f"# App Store Connect Analytics Summary: {app.get('app_slug')}",
        "",
        f"- Window: {manifest.get('window', {}).get('start_date')} to {manifest.get('window', {}).get('end_date')}",
        f"- Report families included: {', '.join(families) if families else 'none'}",
        f"- Raw files: {len([row for row in manifest.get('reports', []) if row.get('raw_path')])}",
        f"- Normalized rows: {total_rows}",
        f"- Completeness: {manifest.get('completeness', {}).get('status', 'unknown')}",
        f"- Caveats: {'; '.join(caveats) if caveats else 'none'}",
        "",
        "## Files",
        "",
    ]
    for row in rows:
        lines.append(f"- `{row.get('artifact_id')}`: `{row.get('raw_path')}` -> `{row.get('normalized_path')}` ({row.get('row_count', 0)} rows)")
    if not rows:
        lines.append("- No raw files were normalized.")
    lines.extend(
        [
            "",
            "## Privacy And Completeness",
            "",
            "Apple may delay reports, suppress low-volume rows, add privacy noise, or omit data below reporting thresholds. Missing rows are treated as insufficient data, not zero activity.",
            "",
        ]
    )
    path.write_text("\n".join(lines))


def main() -> None:
    parser = argparse.ArgumentParser(description="Normalize raw ASC analytics artifacts.")
    parser.add_argument("--artifact-root", required=True)
    args = parser.parse_args()
    normalize_artifact(Path(args.artifact_root))


if __name__ == "__main__":
    main()
