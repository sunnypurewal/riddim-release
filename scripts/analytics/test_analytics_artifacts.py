#!/usr/bin/env python3
import gzip
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import BytesIO, StringIO
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from scripts.analytics.artifact import artifact_root, load_json
from scripts.analytics.asc_client import AscApiError
from scripts.analytics.collect_asc_analytics import build_plan, collect, report_matches


def gz_bytes(text: str) -> bytes:
    out = BytesIO()
    with gzip.GzipFile(fileobj=out, mode="wb", mtime=0) as handle:
        handle.write(text.encode())
    return out.getvalue()


def fixture_config(tmp: Path) -> dict:
    config = load_json(Path(__file__).parent / "fixtures" / "report-catalog.fixture.json")
    config["output"]["root"] = str(tmp / "analytics" / "fixture-app")
    return config


class FakeAscClient:
    def __init__(
        self,
        *,
        data: bytes | None = None,
        report_requests: list[dict] | None = None,
        segments: list[dict] | None = None,
        fail_paths: dict[str, AscApiError] | None = None,
    ):
        self.data = data or gz_bytes("Date\tImpressions\n2026-04-27\t10\n")
        self.report_requests = report_requests
        self.segments = segments
        self.fail_paths = fail_paths or {}
        self.download_count = 0
        self.created_payloads = []
        self.paged_requests = []

    def paged_get(self, path, params=None):
        self.paged_requests.append((path, params or {}))
        if path in self.fail_paths:
            raise self.fail_paths[path]
        if path.endswith("/analyticsReportRequests"):
            if self.report_requests is not None:
                return self.report_requests
            return [{"id": "request-1", "attributes": {"accessType": "ONGOING"}}]
        if path.endswith("/reports"):
            return [
                {
                    "id": "report-1",
                    "attributes": {
                        "category": "APP_STORE_ENGAGEMENT",
                        "name": "App Store Discovery and Engagement Detailed",
                    },
                }
            ]
        if path.endswith("/instances"):
            return [{"id": "instance-1", "attributes": {"granularity": "DAILY", "processingDate": "2026-04-27"}}]
        if path.endswith("/segments"):
            if self.segments is not None:
                return self.segments
            return [
                {"id": "segment-1", "attributes": {"downloadUrl": "https://download.test/segment-1"}},
                {"id": "segment-2", "attributes": {"downloadUrl": "https://download.test/segment-2"}},
            ]
        return []

    def post_json(self, path, payload):
        self.created_payloads.append((path, payload))
        return {"data": {"id": "request-created", "attributes": {"accessType": "ONGOING"}}}

    def download(self, url):
        self.download_count += 1
        return self.data


class AnalyticsCollectorTests(unittest.TestCase):
    def test_dry_run_plan_lists_report_requests(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = fixture_config(Path(tmp))
            plan = build_plan(config, "2026-04-27")
            self.assertEqual(plan[0]["family"], "analytics")
            self.assertEqual(plan[0]["request_type"], "ONGOING")
            self.assertEqual(plan[0]["status"], "planned")

            output = StringIO()
            args = type("Args", (), {"report_date": "2026-04-27", "families": "analytics", "dry_run": True})()
            with redirect_stdout(output):
                collect(config, args)
            self.assertIn('"dry_run": true', output.getvalue())
            self.assertIn('"planned"', output.getvalue())

    def test_create_request_when_explicitly_enabled(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = fixture_config(Path(tmp))
            client = FakeAscClient(report_requests=[])
            args = type(
                "Args",
                (),
                {"report_date": "2026-04-27", "families": "analytics", "dry_run": False, "create_requests": True},
            )()

            manifest = collect(config, args, client=client)

            self.assertEqual(client.created_payloads[0][0], "/v1/analyticsReportRequests")
            self.assertEqual(len(manifest["reports"]), 2)
            self.assertTrue(all(item["status"] == "downloaded" for item in manifest["reports"]))

    def test_catalog_report_codes_match_apple_report_names(self):
        attrs = {
            "category": "APP_STORE_ENGAGEMENT",
            "name": "App Store Discovery and Engagement Detailed",
        }
        spec = {"category": "APP_STORE", "type": "APP_STORE_DISCOVERY"}

        self.assertTrue(report_matches(attrs, spec))

    def test_downloads_all_segments_and_rerun_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = fixture_config(Path(tmp))
            client = FakeAscClient()
            args = type(
                "Args",
                (),
                {"report_date": "2026-04-27", "families": "analytics", "dry_run": False, "create_requests": False},
            )()

            first = collect(config, args, client=client)
            second = collect(config, args, client=client)
            root = artifact_root(config, "2026-04-27")

            self.assertEqual(len(first["reports"]), 2)
            self.assertEqual(len(second["reports"]), 2)
            self.assertEqual(client.download_count, 2)
            self.assertTrue((root / "raw" / "analytics").exists())
            self.assertEqual({item["status"] for item in second["reports"]}, {"unchanged"})
            self.assertEqual(second["completeness"]["status"], "complete")

    def test_missing_segment_refuses_to_mark_instance_complete(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = fixture_config(Path(tmp))
            client = FakeAscClient(segments=[])
            args = type(
                "Args",
                (),
                {"report_date": "2026-04-27", "families": "analytics", "dry_run": False, "create_requests": False},
            )()

            manifest = collect(config, args, client=client)

            self.assertEqual(manifest["reports"][0]["status"], "missing_segment")
            self.assertEqual(manifest["completeness"]["status"], "incomplete")
            self.assertIn("cannot be marked complete", manifest["reports"][0]["status_reason"])

    def test_permission_and_rate_errors_are_manifest_statuses(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = fixture_config(Path(tmp))
            args = type(
                "Args",
                (),
                {"report_date": "2026-04-27", "families": "analytics", "dry_run": False, "create_requests": False},
            )()

            blocked = FakeAscClient(
                fail_paths={
                    "/v1/apps/1234567890/analyticsReportRequests": AscApiError(
                        403,
                        "ASC request is forbidden; check API key role and report-family access.",
                    )
                }
            )
            blocked_manifest = collect(config, args, client=blocked)
            self.assertEqual(blocked_manifest["reports"][0]["status"], "permission_blocked")

            limited = FakeAscClient(
                fail_paths={
                    "/v1/apps/1234567890/analyticsReportRequests": AscApiError(
                        429,
                        "ASC rate limit reached; rerun later.",
                    )
                }
            )
            limited_manifest = collect(config, args, client=limited)
            errors = [item for item in limited_manifest["reports"] if item["status"] == "error"]
            self.assertEqual(len(errors), 1)
            self.assertIn("rerun later", errors[0]["status_reason"])


if __name__ == "__main__":
    unittest.main()
