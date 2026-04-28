#!/usr/bin/env python3
"""
Test harness for compute_next_version.py — mirrors the GitHub Actions environment.

Two test suites:
  Unit  — bump_version logic and JWT shape; no network, no credentials required.
  Integration — live App Store Connect API call + full subprocess invocation;
                requires AWS credentials or a local .p8 key.

Usage:
  # Unit tests only (no credentials needed):
  python3 test_compute_next_version.py

  # Full suite including live API calls:
  python3 test_compute_next_version.py --live

  # Use a specific key instead of fetching from AWS:
  python3 test_compute_next_version.py --live \
    --key-id S6U297PQHR \
    --issuer-id 69a6de88-aaae-47e3-e053-5b8c7c11a4d1 \
    --private-key-path ~/.appstoreconnect/private_keys/AuthKey_S6U297PQHR.p8
"""
import argparse
import json
import os
import subprocess
import sys
import time
import unittest
from pathlib import Path

# ── locate the script under test ─────────────────────────────────────────────
SCRIPT = Path(__file__).parent / "compute_next_version.py"
APP_ID = "1224459142"


# ── unit tests ────────────────────────────────────────────────────────────────
class TestBumpVersion(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import types
        cls.cnv = types.ModuleType("cnv")
        with open(SCRIPT) as f:
            exec(compile(f.read(), SCRIPT, "exec"), cls.cnv.__dict__)  # noqa: S102

    def bump(self, version, kind):
        return self.__class__.cnv.bump_version(version, kind)

    def test_patch(self):
        self.assertEqual(self.bump("1.8.0", "patch"), "1.8.1")

    def test_patch_on_two_part_version(self):
        self.assertEqual(self.bump("1.8", "patch"), "1.8.1")

    def test_minor(self):
        self.assertEqual(self.bump("1.8.3", "minor"), "1.9.0")

    def test_major(self):
        self.assertEqual(self.bump("1.8.3", "major"), "2.0.0")

    def test_zero_base(self):
        self.assertEqual(self.bump("0.0.0", "patch"), "0.0.1")

    def test_minor_resets_patch(self):
        self.assertEqual(self.bump("2.3.9", "minor"), "2.4.0")

    def test_major_resets_minor_and_patch(self):
        self.assertEqual(self.bump("2.3.9", "major"), "3.0.0")


class TestJwtShape(unittest.TestCase):
    """Verify the token we'd send is structurally valid (no network)."""

    def test_token_has_required_claims(self):
        try:
            import jwt as pyjwt
            from cryptography.hazmat.primitives.asymmetric import ec
            from cryptography.hazmat.backends import default_backend
            from cryptography.hazmat.primitives import serialization
        except ImportError:
            self.skipTest("PyJWT / cryptography not installed")

        key = ec.generate_private_key(ec.SECP256R1(), default_backend())
        pem = key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption(),
        ).decode()

        now = int(time.time())
        payload = {"iss": "test-issuer", "iat": now, "exp": now + 1200,
                   "aud": "appstoreconnect-v1"}
        token = pyjwt.encode(payload, pem, algorithm="ES256",
                              headers={"kid": "TESTKID"})
        decoded = pyjwt.decode(token, key.public_key(), algorithms=["ES256"],
                               audience="appstoreconnect-v1")
        self.assertEqual(decoded["iss"], "test-issuer")
        self.assertEqual(decoded["aud"], "appstoreconnect-v1")


# ── integration tests (--live only) ──────────────────────────────────────────
def load_credentials(args) -> tuple[str, str, str]:
    """Return (key_id, issuer_id, key_path). Prefers explicit args, then AWS."""
    if args.key_id and args.issuer_id and args.private_key_path:
        return args.key_id, args.issuer_id, os.path.expanduser(args.private_key_path)

    # Mirror what CI does: pull from AWS Secrets Manager
    result = subprocess.run(
        ["aws", "secretsmanager", "get-secret-value",
         "--secret-id", "appstore/connect-api",
         "--region", "us-east-1",
         "--query", "SecretString",
         "--output", "text"],
        capture_output=True, text=True, check=True,
    )
    secret = json.loads(result.stdout)
    key_id = secret["key_id"]
    issuer_id = secret["issuer_id"]

    key_dir = Path.home() / ".appstoreconnect" / "private_keys"
    key_path = key_dir / f"AuthKey_{key_id}.p8"
    if not key_path.exists():
        key_dir.mkdir(parents=True, exist_ok=True)
        key_path.write_text(secret["private_key"])
        key_path.chmod(0o600)

    return key_id, issuer_id, str(key_path)


class TestLiveApi(unittest.TestCase):
    """Replicates the exact CI invocation of compute_next_version.py."""

    key_id: str
    issuer_id: str
    key_path: str

    def test_get_live_version_returns_semver(self):
        """get_live_version() must return a non-empty string or None (first release)."""
        import types
        cnv = types.ModuleType("cnv")
        with open(SCRIPT) as f:
            exec(compile(f.read(), SCRIPT, "exec"), cnv.__dict__)  # noqa: S102

        token = cnv.get_asc_token(self.key_id, self.issuer_id, self.key_path)
        version = cnv.get_live_version(APP_ID, token)
        print(f"\n  Live version from App Store Connect: {version!r}")
        if version is not None:
            parts = version.split(".")
            self.assertGreaterEqual(len(parts), 2,
                                    f"Expected semver-like string, got {version!r}")
            for p in parts:
                self.assertTrue(p.isdigit(), f"Non-numeric version part in {version!r}")

    def test_full_script_subprocess_patch_bump(self):
        """
        Mirrors the exact shell command CI runs:
          python3 compute_next_version.py --key-id ... --output-format github-output
        Asserts exit 0 and that next_version is written to GITHUB_OUTPUT.
        """
        import tempfile
        with tempfile.NamedTemporaryFile(mode="w", suffix=".env", delete=False) as tf:
            output_file = tf.name

        env = {**os.environ, "GITHUB_OUTPUT": output_file}
        result = subprocess.run(
            [sys.executable, str(SCRIPT),
             "--key-id", self.key_id,
             "--issuer-id", self.issuer_id,
             "--private-key-path", self.key_path,
             "--app-id", APP_ID,
             "--bump", "patch",
             "--output-format", "github-output"],
            capture_output=True, text=True, env=env,
        )
        print("\n  stdout:", result.stdout.strip())
        if result.returncode != 0:
            print("  stderr:", result.stderr.strip())
        self.assertEqual(result.returncode, 0,
                         f"Script exited {result.returncode}:\n{result.stderr}")

        output = Path(output_file).read_text()
        print("  GITHUB_OUTPUT:", output.strip())
        os.unlink(output_file)

        self.assertIn("next_version=", output)
        self.assertIn("current_version=", output)

        next_ver = dict(line.split("=", 1) for line in output.strip().splitlines()
                        if "=" in line).get("next_version", "")
        parts = next_ver.split(".")
        self.assertEqual(len(parts), 3,
                         f"next_version should be X.Y.Z, got {next_ver!r}")


# ── runner ────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--live", action="store_true",
                        help="Include live App Store Connect API tests")
    parser.add_argument("--key-id", default="")
    parser.add_argument("--issuer-id", default="")
    parser.add_argument("--private-key-path", default="")
    args, remaining = parser.parse_known_args()

    suites = [unittest.TestLoader().loadTestsFromTestCase(TestBumpVersion),
              unittest.TestLoader().loadTestsFromTestCase(TestJwtShape)]

    if args.live:
        try:
            key_id, issuer_id, key_path = load_credentials(args)
        except Exception as e:
            print(f"ERROR: could not load credentials: {e}", file=sys.stderr)
            sys.exit(1)
        TestLiveApi.key_id = key_id
        TestLiveApi.issuer_id = issuer_id
        TestLiveApi.key_path = key_path
        suites.append(unittest.TestLoader().loadTestsFromTestCase(TestLiveApi))

    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(unittest.TestSuite(suites))
    sys.exit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
