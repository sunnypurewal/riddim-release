#!/usr/bin/env python3
import json
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

import package_static_site
import validate_manifest


class WebsitePackageTests(unittest.TestCase):
    def test_static_package_includes_well_known_and_excludes_workflow_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            subprocess.run(["git", "init"], cwd=root, check=True, capture_output=True)
            (root / "index.html").write_text("<h1>Riddim</h1>")
            (root / ".well-known").mkdir()
            (root / ".well-known" / "apple-app-site-association").write_text("{}")
            (root / ".github" / "workflows").mkdir(parents=True)
            (root / ".github" / "workflows" / "deploy.yml").write_text("name: deploy")
            (root / "customHttp.yml").write_text("customHeaders: []")
            (root / "docs").mkdir()
            (root / "docs" / "release-process.md").write_text("internal")
            subprocess.run(["git", "add", "."], cwd=root, check=True, capture_output=True)

            artifact = root / "site.zip"
            files = package_static_site.package_files(
                root,
                root,
                artifact,
                package_static_site.DEFAULT_EXCLUDES,
            )

            self.assertIn("index.html", files)
            self.assertIn(".well-known/apple-app-site-association", files)
            self.assertNotIn(".github/workflows/deploy.yml", files)
            self.assertNotIn("customHttp.yml", files)
            self.assertNotIn("docs/release-process.md", files)
            with zipfile.ZipFile(artifact) as archive:
                self.assertIn(".well-known/apple-app-site-association", archive.namelist())


class ManifestTests(unittest.TestCase):
    def test_manifest_validation_checks_artifact_sha(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            artifact = root / "site.zip"
            artifact.write_text("artifact")
            digest = validate_manifest.sha256(artifact)
            manifest = root / "manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "artifact_sha256": digest,
                        "pr_number": "7",
                        "source_sha": "abc123",
                    }
                )
            )

            with mock.patch(
                "sys.argv",
                [
                    "validate_manifest.py",
                    "--manifest",
                    str(manifest),
                    "--artifact",
                    str(artifact),
                    "--pr-number",
                    "7",
                    "--source-sha",
                    "abc123",
                ],
            ):
                validate_manifest.main()


if __name__ == "__main__":
    unittest.main()
