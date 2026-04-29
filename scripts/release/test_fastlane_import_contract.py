import json
import shutil
import subprocess
import textwrap
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def run_shared_fastfile_contract(tmp_path):
    app_fastlane_dir = tmp_path / "ios" / "fastlane"
    app_fastlane_dir.mkdir(parents=True)
    shutil.copy(REPO_ROOT / "fastlane" / "Fastfile", app_fastlane_dir / "Fastfile")

    harness = textwrap.dedent(
        """
        require "json"

        $lanes = {}
        $events = []

        def default_platform(_platform); end
        def platform(_name)
          yield
        end
        def desc(_text); end
        def lane(name, &block)
          $lanes[name] = block
        end

        def app_store_connect_api_key(**kwargs)
          $events << { event: "api_key", key_id: kwargs.fetch(:key_id), issuer_id: kwargs.fetch(:issuer_id) }
          { token: "api-key" }
        end

        def latest_testflight_build_number(api_key:)
          raise "missing api key" unless api_key.fetch(:token) == "api-key"
          40
        end

        def increment_build_number(build_number:, xcodeproj:)
          $events << { event: "increment_build_number", build_number: build_number, xcodeproj: xcodeproj }
        end

        def increment_version_number(version_number:, xcodeproj:)
          $events << { event: "increment_version_number", version_number: version_number, xcodeproj: xcodeproj }
        end

        def sigh(api_key:, app_identifier:, force:)
          raise "missing api key" unless api_key.fetch(:token) == "api-key"
          $events << { event: "sigh", app_identifier: app_identifier, force: force }
          "profile-#{app_identifier}"
        end

        def update_code_signing_settings(**kwargs)
          $events << {
            event: "update_code_signing_settings",
            path: kwargs.fetch(:path),
            team_id: kwargs.fetch(:team_id),
            targets: kwargs.fetch(:targets),
            profile_uuid: kwargs.fetch(:profile_uuid)
          }
        end

        def build_app(**kwargs)
          $events << { event: "build_app", scheme: kwargs.fetch(:scheme), xcargs: kwargs.fetch(:xcargs) }
        end

        def upload_to_testflight(**kwargs)
          $events << { event: "upload_to_testflight", ipa: kwargs.fetch(:ipa) }
        end

        ENV["ASC_KEY_ID"] = "KEY123"
        ENV["ASC_ISSUER_ID"] = "ISSUER123"
        ENV["NEW_VERSION"] = "2.3.4"
        ENV["SENTRY_DSN"] = ""

        load "Fastfile"
        $lanes.fetch(:deploy).call(
          scheme: "BubbleBop",
          bundle_id: "com.riddimsoftware.bap",
          team_id: "ZG82TFXU3C",
          xcodeproj: "BubbleBop.xcodeproj",
          extra_bundle_ids: "com.riddimsoftware.bap.Share=ShareExtension"
        )

        puts JSON.generate($events)
        """
    )

    result = subprocess.run(
        ["ruby", "-e", harness],
        cwd=app_fastlane_dir,
        check=True,
        text=True,
        capture_output=True,
    )

    events = json.loads(result.stdout)

    assert {"event": "api_key", "key_id": "KEY123", "issuer_id": "ISSUER123"} in events
    assert {
        "event": "sigh",
        "app_identifier": "com.riddimsoftware.bap",
        "force": False,
    } in events
    assert {
        "event": "sigh",
        "app_identifier": "com.riddimsoftware.bap.Share",
        "force": False,
    } in events
    assert {
        "event": "update_code_signing_settings",
        "path": "BubbleBop.xcodeproj",
        "team_id": "ZG82TFXU3C",
        "targets": ["BubbleBop"],
        "profile_uuid": "profile-com.riddimsoftware.bap",
    } in events
    assert {
        "event": "update_code_signing_settings",
        "path": "BubbleBop.xcodeproj",
        "team_id": "ZG82TFXU3C",
        "targets": ["ShareExtension"],
        "profile_uuid": "profile-com.riddimsoftware.bap.Share",
    } in events
    assert (app_fastlane_dir / "build_number.txt").read_text() == "41"


def test_shared_fastfile_runs_when_imported_without_helper_directory(tmp_path):
    run_shared_fastfile_contract(tmp_path)


class FastlaneImportContractTest(unittest.TestCase):
    def test_shared_fastfile_runs_without_helper_directory(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            run_shared_fastfile_contract(Path(tmp_dir))


if __name__ == "__main__":
    unittest.main()
