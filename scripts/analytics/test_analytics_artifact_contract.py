#!/usr/bin/env python3
import json
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_ROOT = REPO_ROOT / "docs" / "analytics" / "fixtures"

REQUIRED_REPORT_FIELDS = {
    "artifact_id",
    "family",
    "category",
    "type",
    "subtype",
    "granularity",
    "requested_date",
    "requested_window",
    "request_id",
    "report_id",
    "instance_id",
    "segment_id",
    "download_url_source",
    "raw_path",
    "downloaded_at",
    "checksum_sha256",
    "byte_count",
    "row_count",
    "status",
    "status_reason",
    "normalized_path",
    "schema_path",
}

VALID_STATUSES = {
    "planned",
    "downloaded",
    "unchanged",
    "normalized",
    "empty",
    "delayed",
    "thresholded",
    "permission_blocked",
    "unavailable",
    "missing_segment",
    "error",
}


class AnalyticsArtifactFixtureTests(unittest.TestCase):
    def load_fixture(self, name):
        with (FIXTURE_ROOT / name).open() as handle:
            return json.load(handle)

    def test_report_catalog_contains_required_sections(self):
        catalog = self.load_fixture("report-catalog.example.json")

        self.assertEqual(catalog["catalog_version"], 1)
        self.assertEqual(catalog["output"]["root"], "docs/analytics/app-store-connect/pleaseplay")
        self.assertTrue(catalog["output"]["raw_immutable"])
        self.assertIn("business_context_mappings", catalog)

        app = catalog["app"]
        for field in ("app_id", "bundle_id", "app_slug"):
            self.assertTrue(app[field])

        families = catalog["families"]
        for family in ("analytics_reports", "sales_trends", "finance"):
            self.assertIn("enabled", families[family])
            self.assertIn("reports", families[family])

        analytics_report = families["analytics_reports"]["reports"][0]
        self.assertIn("type", analytics_report)
        self.assertIn("granularities", analytics_report)

    def test_manifest_reports_have_contract_fields_and_statuses(self):
        manifest = self.load_fixture("manifest.example.json")

        self.assertEqual(manifest["artifact_version"], 1)
        self.assertTrue(manifest["tool_version"])
        self.assertEqual(manifest["app"]["app_slug"], "pleaseplay")
        self.assertEqual(manifest["window"]["start_date"], "2026-04-27")
        self.assertEqual(manifest["window"]["end_date"], "2026-04-27")

        reports = manifest["reports"]
        self.assertGreaterEqual(len(reports), 3)
        for report in reports:
            self.assertTrue(REQUIRED_REPORT_FIELDS.issubset(report.keys()))
            self.assertIn(report["status"], VALID_STATUSES)
            if report["raw_path"] is not None:
                self.assertTrue(report["raw_path"].startswith("docs/analytics/app-store-connect/"))
            if report["status"] in {"delayed", "thresholded", "permission_blocked", "missing_segment"}:
                self.assertTrue(report["status_reason"])

    def test_manifest_distinguishes_missing_data_from_zero_activity(self):
        manifest = self.load_fixture("manifest.example.json")
        statuses = {report["status"] for report in manifest["reports"]}

        self.assertIn("delayed", statuses)
        self.assertIn("permission_blocked", statuses)
        self.assertEqual(manifest["completeness"]["status"], "incomplete")
        caveats = " ".join(manifest["completeness"]["caveats"])
        self.assertIn("must not be interpreted as zero", caveats)


if __name__ == "__main__":
    unittest.main()
