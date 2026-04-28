#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import date
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.analytics.artifact import (
    atomic_write_bytes,
    artifact_root,
    count_gzip_tsv_rows,
    existing_report,
    load_manifest,
    manifest_entry,
    sha256_bytes,
    slugify,
    upsert_report,
    utc_now,
    write_json,
)
from scripts.analytics.asc_client import AscApiError, AscClient, get_asc_token
from scripts.analytics.catalog import analytics_enabled, analytics_family, analytics_request_type, app_id, load_catalog
from scripts.analytics.catalog import finance_enabled, finance_family, sales_enabled, sales_family, vendor_number


SUPPORTED_FAMILIES = {"analytics", "sales", "finance"}


def build_plan(config: dict[str, Any], report_date: str, families: set[str] | None = None) -> list[dict[str, Any]]:
    selected = families or enabled_families(config)
    plan: list[dict[str, Any]] = []
    if "analytics" in selected:
        plan.extend(build_analytics_plan(config, report_date))
    if "sales" in selected:
        plan.extend(build_sales_plan(config, report_date))
    if "finance" in selected:
        plan.extend(build_finance_plan(config, report_date))
    return plan


def enabled_families(config: dict[str, Any]) -> set[str]:
    families: set[str] = set()
    if analytics_enabled(config):
        families.add("analytics")
    if sales_enabled(config):
        families.add("sales")
    if finance_enabled(config):
        families.add("finance")
    return families


def build_analytics_plan(config: dict[str, Any], report_date: str) -> list[dict[str, Any]]:
    family = analytics_family(config)
    plan: list[dict[str, Any]] = []
    for report in family.get("reports", []):
        granularities = report.get("granularities") or family.get("granularities") or ["DAILY"]
        for granularity in granularities:
            plan.append(
                {
                    "family": "analytics",
                    "request_type": analytics_request_type(family),
                    "app_id": app_id(config),
                    "category": report.get("category"),
                    "type": report.get("type") or report.get("name"),
                    "granularity": granularity,
                    "requested_date": report_date,
                    "status": "planned",
                }
            )
    return plan


def build_sales_plan(config: dict[str, Any], report_date: str) -> list[dict[str, Any]]:
    plan: list[dict[str, Any]] = []
    for report in sales_family(config).get("reports", []):
        params = sales_params(config, report, report_date)
        plan.append({"family": "sales", "endpoint": "/v1/salesReports", "params": params, "status": "planned"})
    return plan


def build_finance_plan(config: dict[str, Any], report_date: str) -> list[dict[str, Any]]:
    plan: list[dict[str, Any]] = []
    for report in finance_family(config).get("reports", []):
        params = finance_params(config, report, report_date)
        plan.append({"family": "finance", "endpoint": "/v1/financeReports", "params": params, "status": "planned"})
    return plan


def require_client(args: argparse.Namespace) -> AscClient:
    key_id = args.key_id or os.environ.get("ASC_KEY_ID")
    issuer_id = args.issuer_id or os.environ.get("ASC_ISSUER_ID")
    private_key_path = args.private_key_path or os.environ.get("ASC_PRIVATE_KEY_PATH")
    if not (key_id and issuer_id and private_key_path):
        raise SystemExit("ASC credentials are required unless --dry-run is set.")
    return AscClient(get_asc_token(key_id, issuer_id, private_key_path))


def collect(
    config: dict[str, Any],
    args: argparse.Namespace,
    client: AscClient | None = None,
) -> dict[str, Any]:
    report_date = args.report_date or date.today().isoformat()
    requested = (
        {item.strip() for item in args.families.split(",") if item.strip()}
        if args.families
        else enabled_families(config)
    )
    unsupported = requested - SUPPORTED_FAMILIES
    if unsupported:
        raise SystemExit(f"Unsupported report families: {', '.join(sorted(unsupported))}")

    plan = build_plan(config, report_date, requested)
    if args.dry_run:
        result = {"dry_run": True, "report_date": report_date, "plan": plan}
        print(json.dumps(result, indent=2, sort_keys=True))
        return result

    root = artifact_root(config, report_date)
    manifest = load_manifest(root, config, report_date)
    asc_client = client or require_client(args)
    if "analytics" in requested and analytics_enabled(config):
        collect_analytics(config, asc_client, manifest, report_date, bool(args.create_requests))
    if "sales" in requested and sales_enabled(config):
        collect_sales(config, asc_client, manifest, report_date)
    if "finance" in requested and finance_enabled(config):
        collect_finance(config, asc_client, manifest, report_date)
    write_json(root / "manifest.json", manifest)
    return manifest


def collect_analytics(
    config: dict[str, Any],
    client: AscClient,
    manifest: dict[str, Any],
    report_date: str,
    create_requests: bool,
) -> None:
    family = analytics_family(config)
    request_type = analytics_request_type(family)
    application_id = app_id(config)
    try:
        report_request = find_report_request(client, application_id, request_type)
        if not report_request and create_requests:
            report_request = create_report_request(client, application_id, request_type)
        if not report_request:
            upsert_report(
                manifest,
                manifest_entry(
                    config,
                    artifact_id=slugify(f"analytics-request-{application_id}-{request_type}"),
                    category=None,
                    report_type=None,
                    subtype=None,
                    granularity=None,
                    requested_date=report_date,
                    requested_window=None,
                    request_id=None,
                    report_id=None,
                    instance_id=None,
                    segment_id=None,
                    download_url_source=f"/v1/apps/{application_id}/analyticsReportRequests",
                    raw_path=None,
                    status="unavailable",
                    status_reason=(
                        "No Analytics Report request exists; rerun with "
                        "--create-requests using an Admin API key."
                    ),
                ),
            )
            return

        request_id = str(report_request["id"])
        reports = client.paged_get(f"/v1/analyticsReportRequests/{request_id}/reports", {"limit": 200})
        wanted = family.get("reports", [])
        for report in reports:
            attrs = report.get("attributes", {})
            if wanted and not any(report_matches(attrs, spec) for spec in wanted):
                continue
            granularities = matching_granularities(attrs, wanted) or family.get("granularities") or ["DAILY"]
            for granularity in granularities:
                collect_report_instances(config, client, manifest, report_date, request_id, report, str(granularity))
    except AscApiError as exc:
        upsert_report(
            manifest,
            manifest_entry(
                config,
                artifact_id=slugify(f"analytics-error-{application_id}-{request_type}-{exc.status_code}"),
                category=None,
                report_type=None,
                subtype=None,
                granularity=None,
                requested_date=report_date,
                requested_window=None,
                request_id=None,
                report_id=None,
                instance_id=None,
                segment_id=None,
                download_url_source=f"/v1/apps/{application_id}/analyticsReportRequests",
                raw_path=None,
                status=exc.manifest_status,
                status_reason=str(exc),
            ),
        )


def collect_sales(
    config: dict[str, Any],
    client: AscClient,
    manifest: dict[str, Any],
    report_date: str,
) -> None:
    for report in sales_family(config).get("reports", []):
        params = sales_params(config, report, report_date)
        artifact_id = slugify(f"sales-{params['filter[frequency]']}-{params['filter[reportDate]']}-"
                              f"{params['filter[reportType]']}-{params['filter[reportSubType]']}")
        raw_path = endpoint_raw_path(config, report_date, "sales", artifact_id)
        entry = manifest_entry(
            config,
            artifact_id=artifact_id,
            family="sales",
            category="SALES_AND_TRENDS",
            report_type=params["filter[reportType]"],
            subtype=params["filter[reportSubType]"],
            granularity=params["filter[frequency]"],
            requested_date=params["filter[reportDate]"],
            requested_window=None,
            request_id=None,
            report_id=None,
            instance_id=None,
            segment_id=None,
            download_url_source="/v1/salesReports",
            raw_path=None,
            status="planned",
            status_reason=None,
        )
        collect_endpoint_report(client, manifest, artifact_id, raw_path, "/v1/salesReports", params, entry)


def collect_finance(
    config: dict[str, Any],
    client: AscClient,
    manifest: dict[str, Any],
    report_date: str,
) -> None:
    for report in finance_family(config).get("reports", []):
        params = finance_params(config, report, report_date)
        artifact_id = slugify(f"finance-{params['filter[regionCode]']}-{params['filter[reportDate]']}-"
                              f"{params['filter[reportType]']}")
        raw_path = endpoint_raw_path(config, report_date, "finance", artifact_id)
        entry = manifest_entry(
            config,
            artifact_id=artifact_id,
            family="finance",
            category="FINANCE",
            report_type=params["filter[reportType]"],
            subtype=None,
            granularity="MONTHLY",
            requested_date=None,
            requested_window={
                "fiscal_period": params["filter[reportDate]"],
                "region": params["filter[regionCode]"],
            },
            request_id=None,
            report_id=None,
            instance_id=None,
            segment_id=None,
            download_url_source="/v1/financeReports",
            raw_path=None,
            status="planned",
            status_reason=None,
        )
        collect_endpoint_report(client, manifest, artifact_id, raw_path, "/v1/financeReports", params, entry)


def sales_params(config: dict[str, Any], report: dict[str, Any], report_date: str) -> dict[str, str]:
    return {
        "filter[frequency]": str(report.get("frequency", "DAILY")),
        "filter[reportDate]": str(report.get("report_date") or report_date),
        "filter[reportSubType]": str(report.get("report_subtype", "SUMMARY")),
        "filter[reportType]": str(report.get("report_type", "SALES")),
        "filter[vendorNumber]": vendor_number(config, report),
        "filter[version]": str(report.get("version", "1_0")),
    }


def finance_params(config: dict[str, Any], report: dict[str, Any], report_date: str) -> dict[str, str]:
    required = {
        "region_code": report.get("region_code"),
        "report_date": report.get("report_date") or report_date[:7],
        "report_type": report.get("report_type", "FINANCIAL"),
        "vendor_number": vendor_number(config, report),
    }
    missing = [key for key, value in required.items() if not value]
    if missing:
        raise SystemExit(f"Finance report config missing required fields: {', '.join(missing)}")
    return {
        "filter[regionCode]": str(required["region_code"]),
        "filter[reportDate]": str(required["report_date"]),
        "filter[reportType]": str(required["report_type"]),
        "filter[vendorNumber]": str(required["vendor_number"]),
    }


def endpoint_raw_path(config: dict[str, Any], report_date: str, family: str, artifact_id: str) -> Path:
    return artifact_root(config, report_date) / "raw" / family / f"{artifact_id}.txt.gz"


def collect_endpoint_report(
    client: AscClient,
    manifest: dict[str, Any],
    artifact_id: str,
    raw_path: Path,
    endpoint: str,
    params: dict[str, str],
    entry: dict[str, Any],
) -> None:
    try:
        status = write_endpoint_report_once(client, manifest, artifact_id, raw_path, endpoint, params)
        upsert_report(manifest, {**entry, **manifest_entry_from_raw(entry, raw_path, status)})
    except AscApiError as exc:
        upsert_report(manifest, {**entry, "status": exc.manifest_status, "status_reason": str(exc)})


def write_endpoint_report_once(
    client: AscClient,
    manifest: dict[str, Any],
    artifact_id: str,
    raw_path: Path,
    endpoint: str,
    params: dict[str, str],
) -> str:
    existing = existing_report(manifest, artifact_id)
    if raw_path.exists():
        checksum = sha256_bytes(raw_path.read_bytes())
        recorded_checksum = existing.get("checksum_sha256") if existing else None
        if recorded_checksum and checksum != recorded_checksum:
            raise RuntimeError(
                f"Existing raw report checksum mismatch for {raw_path}; "
                "refusing to rewrite immutable raw file."
            )
        return "unchanged"
    response = client.request("GET", endpoint, params=params)
    data = response.content
    downloaded_checksum = sha256_bytes(data)
    if existing and existing.get("checksum_sha256") and existing["checksum_sha256"] != downloaded_checksum:
        raise RuntimeError(f"Downloaded report checksum changed for {artifact_id}; refusing to overwrite raw file.")
    atomic_write_bytes(raw_path, data)
    return "downloaded"


def manifest_entry_from_raw(entry: dict[str, Any], raw_path: Path, status: str) -> dict[str, Any]:
    return {
        "raw_path": str(raw_path),
        "downloaded_at": utc_now(),
        "checksum_sha256": sha256_bytes(raw_path.read_bytes()),
        "byte_count": raw_path.stat().st_size,
        "row_count": count_gzip_tsv_rows(raw_path),
        "status": status,
        "status_reason": None,
    }


def find_report_request(client: AscClient, application_id: str, request_type: str) -> dict[str, Any] | None:
    requests = client.paged_get(
        f"/v1/apps/{application_id}/analyticsReportRequests",
        {
            "filter[accessType]": request_type,
            "fields[analyticsReportRequests]": "accessType,stoppedDueToInactivity",
            "limit": 200,
        },
    )
    return next((item for item in requests if item.get("attributes", {}).get("accessType") == request_type), None)


def create_report_request(client: AscClient, application_id: str, request_type: str) -> dict[str, Any]:
    response = client.post_json(
        "/v1/analyticsReportRequests",
        {
            "data": {
                "type": "analyticsReportRequests",
                "attributes": {"accessType": request_type},
                "relationships": {"app": {"data": {"type": "apps", "id": application_id}}},
            }
        },
    )
    return response["data"]


def collect_report_instances(
    config: dict[str, Any],
    client: AscClient,
    manifest: dict[str, Any],
    report_date: str,
    request_id: str,
    report: dict[str, Any],
    granularity: str,
) -> None:
    report_attrs = report.get("attributes", {})
    instances = client.paged_get(
        f"/v1/analyticsReports/{report['id']}/instances",
        {"filter[granularity]": granularity, "filter[processingDate]": report_date, "limit": 200},
    )
    if not instances:
        upsert_report(
            manifest,
            manifest_entry(
                config,
                artifact_id=slugify(f"analytics-{report['id']}-{granularity}-{report_date}"),
                category=report_attrs.get("category"),
                report_type=report_attrs.get("name") or report_attrs.get("type"),
                subtype=report_attrs.get("subtype"),
                granularity=granularity,
                requested_date=report_date,
                requested_window=None,
                request_id=request_id,
                report_id=report["id"],
                instance_id=None,
                segment_id=None,
                download_url_source=f"/v1/analyticsReports/{report['id']}/instances",
                raw_path=None,
                status="delayed",
                status_reason="Apple has not generated a report instance for this processing date.",
            ),
        )
        return

    for instance in instances:
        collect_instance_segments(config, client, manifest, report_date, request_id, report, instance)


def collect_instance_segments(
    config: dict[str, Any],
    client: AscClient,
    manifest: dict[str, Any],
    report_date: str,
    request_id: str,
    report: dict[str, Any],
    instance: dict[str, Any],
) -> None:
    report_attrs = report.get("attributes", {})
    instance_attrs = instance.get("attributes", {})
    segments = client.paged_get(f"/v1/analyticsReportInstances/{instance['id']}/segments", {"limit": 200})
    if not segments:
        state_status, state_reason = instance_state_status(instance_attrs)
        upsert_report(
            manifest,
            manifest_entry(
                config,
                artifact_id=slugify(f"analytics-{report['id']}-{instance['id']}-segments"),
                category=report_attrs.get("category"),
                report_type=report_attrs.get("name") or report_attrs.get("type"),
                subtype=report_attrs.get("subtype"),
                granularity=instance_attrs.get("granularity"),
                requested_date=instance_attrs.get("processingDate") or report_date,
                requested_window=None,
                request_id=request_id,
                report_id=report["id"],
                instance_id=instance["id"],
                segment_id=None,
                download_url_source=f"/v1/analyticsReportInstances/{instance['id']}/segments",
                raw_path=None,
                status=state_status,
                status_reason=state_reason,
            ),
        )
        return

    for segment in segments:
        collect_segment(config, client, manifest, report_date, request_id, report, instance, segment)


def collect_segment(
    config: dict[str, Any],
    client: AscClient,
    manifest: dict[str, Any],
    report_date: str,
    request_id: str,
    report: dict[str, Any],
    instance: dict[str, Any],
    segment: dict[str, Any],
) -> None:
    report_attrs = report.get("attributes", {})
    instance_attrs = instance.get("attributes", {})
    segment_attrs = segment.get("attributes", {})
    download_url = segment_attrs.get("url") or segment_attrs.get("downloadUrl")
    artifact_id = slugify(f"analytics-{report['id']}-{instance['id']}-{segment['id']}")
    if not download_url:
        upsert_report(
            manifest,
            manifest_entry(
                config,
                artifact_id=artifact_id,
                category=report_attrs.get("category"),
                report_type=report_attrs.get("name") or report_attrs.get("type"),
                subtype=report_attrs.get("subtype"),
                granularity=instance_attrs.get("granularity"),
                requested_date=instance_attrs.get("processingDate") or report_date,
                requested_window=None,
                request_id=request_id,
                report_id=report["id"],
                instance_id=instance["id"],
                segment_id=segment["id"],
                download_url_source=f"/v1/analyticsReportSegments/{segment['id']}",
                raw_path=None,
                status="missing_segment",
                status_reason="Analytics report segment did not include a download URL.",
            ),
        )
        return

    root = artifact_root(config, report_date)
    raw_path = (
        root
        / "raw"
        / "analytics"
        / slugify(report_attrs.get("name") or report["id"])
        / slugify(instance_attrs.get("granularity") or "unknown")
        / (instance_attrs.get("processingDate") or report_date)
        / instance["id"]
        / f"{segment['id']}.txt.gz"
    )
    status = write_segment_once(client, manifest, artifact_id, raw_path, download_url)
    upsert_report(
        manifest,
        manifest_entry(
            config,
            artifact_id=artifact_id,
            category=report_attrs.get("category"),
            report_type=report_attrs.get("name") or report_attrs.get("type"),
            subtype=report_attrs.get("subtype"),
            granularity=instance_attrs.get("granularity"),
            requested_date=instance_attrs.get("processingDate") or report_date,
            requested_window=None,
            request_id=request_id,
            report_id=report["id"],
            instance_id=instance["id"],
            segment_id=segment["id"],
            download_url_source=f"/v1/analyticsReportSegments/{segment['id']}",
            raw_path=raw_path,
            status=status,
            status_reason=None,
        ),
    )


def write_segment_once(
    client: AscClient,
    manifest: dict[str, Any],
    artifact_id: str,
    raw_path: Path,
    download_url: str,
) -> str:
    existing = existing_report(manifest, artifact_id)
    if raw_path.exists():
        checksum = sha256_bytes(raw_path.read_bytes())
        recorded_checksum = existing.get("checksum_sha256") if existing else None
        if recorded_checksum and checksum != recorded_checksum:
            raise RuntimeError(
                f"Existing raw segment checksum mismatch for {raw_path}; "
                "refusing to rewrite immutable raw file."
            )
        return "unchanged"

    data = client.download(download_url)
    downloaded_checksum = sha256_bytes(data)
    if existing and existing.get("checksum_sha256") and existing["checksum_sha256"] != downloaded_checksum:
        raise RuntimeError(
            f"Downloaded segment checksum changed for {artifact_id}; "
            "refusing to overwrite immutable raw file."
        )
    atomic_write_bytes(raw_path, data)
    return "downloaded"


def report_matches(attrs: dict[str, Any], spec: dict[str, Any]) -> bool:
    expected_category = spec.get("category")
    expected_type = spec.get("type") or spec.get("name")
    actual_category = attrs.get("category")
    actual_type = attrs.get("name") or attrs.get("type")
    return soft_match(expected_category, actual_category) and soft_match(expected_type, actual_type)


def soft_match(expected: Any, actual: Any) -> bool:
    if not expected:
        return True
    if not actual:
        return False
    expected_key = rekey(expected)
    actual_key = rekey(actual)
    return expected_key == actual_key or expected_key in actual_key


def rekey(value: Any) -> str:
    return "".join(ch for ch in str(value).lower() if ch.isalnum())


def matching_granularities(attrs: dict[str, Any], specs: list[dict[str, Any]]) -> list[str]:
    granularities: list[str] = []
    for spec in specs:
        if report_matches(attrs, spec):
            granularities.extend(str(item) for item in spec.get("granularities", []))
    return granularities


def instance_state_status(attrs: dict[str, Any]) -> tuple[str, str]:
    state = str(attrs.get("state") or attrs.get("status") or attrs.get("processingState") or "").upper()
    reason = str(attrs.get("stateReason") or attrs.get("message") or "").strip()
    if "THRESHOLD" in state or "PRIVACY" in state:
        return "thresholded", reason or "Apple withheld this report instance because of privacy thresholds."
    if "EMPTY" in state or "NO_DATA" in state:
        return "empty", reason or "Apple generated an empty report instance."
    if "PROCESS" in state or "PENDING" in state:
        return "delayed", reason or "Apple has not finished generating this report instance."
    return "missing_segment", reason or "Report instance has no downloadable segments and cannot be marked complete."


def main() -> None:
    parser = argparse.ArgumentParser(description="Collect App Store Connect report artifacts.")
    parser.add_argument("--config", required=True)
    parser.add_argument("--report-date", default="")
    parser.add_argument(
        "--families",
        default="",
        help="Comma-separated subset: analytics,sales,finance. Defaults to all enabled families.",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--create-requests",
        action="store_true",
        help="Create missing report requests using an Admin key.",
    )
    parser.add_argument("--key-id", default="")
    parser.add_argument("--issuer-id", default="")
    parser.add_argument("--private-key-path", default="")
    args = parser.parse_args()
    collect(load_catalog(args.config), args)


if __name__ == "__main__":
    main()
