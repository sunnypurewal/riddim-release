#!/usr/bin/env python3
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

import generate_release_notes
import verify_evidence


class GenerateReleaseNotesTests(unittest.TestCase):
    def test_output_is_required(self):
        with mock.patch.object(sys, "argv", ["generate_release_notes.py"]):
            with redirect_stderr(StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    generate_release_notes.main()
        self.assertNotEqual(raised.exception.code, 0)

    def test_writes_to_required_output_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "metadata" / "release_notes.txt"
            with (
                mock.patch.object(
                    sys,
                    "argv",
                    ["generate_release_notes.py", "--output", str(output)],
                ),
                mock.patch.object(generate_release_notes, "get_last_release_tag", return_value="v1.0.0"),
                mock.patch.object(generate_release_notes, "get_merged_pr_numbers", return_value=["123"]),
                mock.patch.object(
                    generate_release_notes,
                    "extract_release_notes_from_pr",
                    return_value=["Ship the thing"],
                ),
                redirect_stdout(StringIO()),
            ):
                generate_release_notes.main()

            self.assertEqual(
                output.read_text(),
                "What's new in this release:\n\n• Ship the thing\n",
            )


class VerifyEvidenceTests(unittest.TestCase):
    def test_ticket_prefix_filters_merge_lines_and_evidence_files(self):
        pr_lines = [
            "abc123 Merge pull request #1 from branch RIDDIM-123 add release scripts",
            "def456 Merge pull request #2 from branch EPAC-999 unrelated",
        ]

        self.assertEqual(
            verify_evidence.extract_ticket_ids(pr_lines, "RIDDIM"),
            {"RIDDIM-123"},
        )

        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "RIDDIM-123-release-script.png").touch()
            Path(tmp, "EPAC-999-unrelated.png").touch()
            self.assertEqual(
                verify_evidence.get_evidenced_tickets(tmp, "RIDDIM"),
                {"RIDDIM-123"},
            )


if __name__ == "__main__":
    unittest.main()
