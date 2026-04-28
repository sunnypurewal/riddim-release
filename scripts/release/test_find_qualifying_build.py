#!/usr/bin/env python3
import unittest
from datetime import datetime, timezone
from unittest import mock

import find_qualifying_build


class FakeResponse:
    def __init__(self, payload):
        self.payload = payload

    def raise_for_status(self):
        return None

    def json(self):
        return self.payload


def build_payload():
    return {
        "data": [
            {
                "attributes": {
                    "version": "42",
                    "uploadedDate": "2026-04-28T10:15:00Z",
                    "processingState": "VALID",
                },
                "relationships": {
                    "preReleaseVersion": {
                        "data": {
                            "id": "pre-release-1",
                            "type": "preReleaseVersions",
                        }
                    }
                },
            }
        ],
        "included": [
            {
                "id": "pre-release-1",
                "type": "preReleaseVersions",
                "attributes": {"version": "1.2.3"},
            }
        ],
    }


class FindQualifyingBuildTests(unittest.TestCase):
    def test_finds_latest_matching_fake_tag_version(self):
        fake_tag = "v1.2.3"
        version = fake_tag.removeprefix("v")

        with mock.patch.object(
            find_qualifying_build.requests,
            "get",
            return_value=FakeResponse(build_payload()),
        ):
            result = find_qualifying_build.find_qualifying_build(
                app_id="1234567890",
                cutoff_dt=None,
                token="token",
                override=None,
                version=version,
            )

        self.assertEqual(
            result,
            {
                "build_number": "42",
                "build_version": "1.2.3",
                "upload_time": "2026-04-28T10:15:00Z",
            },
        )

    def test_rejects_build_after_cutoff(self):
        with mock.patch.object(
            find_qualifying_build.requests,
            "get",
            return_value=FakeResponse(build_payload()),
        ):
            with self.assertRaises(SystemExit):
                find_qualifying_build.find_qualifying_build(
                    app_id="1234567890",
                    cutoff_dt=datetime(2026, 4, 28, 10, 0, tzinfo=timezone.utc),
                    token="token",
                    override=None,
                    version="1.2.3",
                )


if __name__ == "__main__":
    unittest.main()
